import 'dart:convert';
import 'dart:typed_data';

/// Error correction level of a QR code.
enum QrEcc {
  low(1),
  medium(0),
  quartile(3),
  high(2);

  const QrEcc(this.formatBits);

  /// The 2-bit indicator written into the format information.
  final int formatBits;
}

/// Minimal QR code encoder (ISO/IEC 18004), byte mode, versions 1 to 40.
///
/// Used to show invite links as scannable codes without a third-party
/// package. Verified module-for-module against a reference implementation in
/// the unit tests.
class QrCode {
  QrCode._(this.version, this.ecc, this.mask, this._modules) : size = version * 4 + 17;

  final int version;
  final QrEcc ecc;

  /// Mask pattern 0 to 7 that was applied.
  final int mask;
  final int size;
  final List<List<bool>> _modules;

  /// Dark module at column [x], row [y]; false outside the symbol.
  bool moduleAt(int x, int y) => x >= 0 && y >= 0 && x < size && y < size && _modules[y][x];

  /// Encodes [text] as UTF-8 bytes. Throws [ArgumentError] when it does not
  /// fit in version 40. A fixed [mask] (0..7) is only for tests.
  static QrCode encodeText(
    String text, {
    QrEcc ecc = QrEcc.medium,
    int minVersion = 1,
    int? mask,
  }) =>
      encodeBytes(utf8.encode(text), ecc: ecc, minVersion: minVersion, mask: mask);

  static QrCode encodeBytes(
    List<int> data, {
    QrEcc ecc = QrEcc.medium,
    int minVersion = 1,
    int? mask,
  }) {
    var version = minVersion;
    int capacityBits;
    while (true) {
      capacityBits = _numDataCodewords(version, ecc) * 8;
      final needed = 4 + (version < 10 ? 8 : 16) + data.length * 8;
      if (needed <= capacityBits) break;
      if (version >= 40) throw ArgumentError('Data too long for a QR code');
      version++;
    }

    final bits = _BitBuffer()
      ..append(0x4, 4)
      ..append(data.length, version < 10 ? 8 : 16);
    for (final b in data) {
      bits.append(b, 8);
    }
    bits.append(0, (capacityBits - bits.length).clamp(0, 4));
    bits.append(0, (8 - bits.length % 8) % 8);
    for (var pad = 0xEC; bits.length < capacityBits; pad ^= 0xEC ^ 0x11) {
      bits.append(pad, 8);
    }
    final codewords = _addEccAndInterleave(bits.toBytes(), version, ecc);
    return _build(version, ecc, codewords, mask);
  }

  // --- construction ------------------------------------------------------

  static QrCode _build(int version, QrEcc ecc, Uint8List codewords, int? forcedMask) {
    final size = version * 4 + 17;
    final modules = List.generate(size, (_) => List<bool>.filled(size, false));
    final isFunction = List.generate(size, (_) => List<bool>.filled(size, false));

    void setFunction(int x, int y, bool dark) {
      modules[y][x] = dark;
      isFunction[y][x] = true;
    }

    // Timing patterns.
    for (var i = 0; i < size; i++) {
      setFunction(6, i, i % 2 == 0);
      setFunction(i, 6, i % 2 == 0);
    }
    // Finder patterns with separators.
    void finder(int cx, int cy) {
      for (var dy = -4; dy <= 4; dy++) {
        for (var dx = -4; dx <= 4; dx++) {
          final dist = dx.abs() > dy.abs() ? dx.abs() : dy.abs();
          final x = cx + dx;
          final y = cy + dy;
          if (x >= 0 && x < size && y >= 0 && y < size) {
            setFunction(x, y, dist != 2 && dist != 4);
          }
        }
      }
    }

    finder(3, 3);
    finder(size - 4, 3);
    finder(3, size - 4);
    // Alignment patterns.
    final align = _alignmentPositions(version);
    for (var i = 0; i < align.length; i++) {
      for (var j = 0; j < align.length; j++) {
        final skip = (i == 0 && j == 0) ||
            (i == 0 && j == align.length - 1) ||
            (i == align.length - 1 && j == 0);
        if (skip) continue;
        for (var dy = -2; dy <= 2; dy++) {
          for (var dx = -2; dx <= 2; dx++) {
            final d = dx.abs() > dy.abs() ? dx.abs() : dy.abs();
            setFunction(align[i] + dx, align[j] + dy, d != 1);
          }
        }
      }
    }
    // Reserve format and version areas so data is not placed there.
    _drawFormat(ecc, 0, size, setFunction);
    _drawVersion(version, size, setFunction);

    // Data bits in the zigzag order.
    var bitIndex = 0;
    final totalBits = codewords.length * 8;
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right == 6) right = 5;
      for (var vert = 0; vert < size; vert++) {
        for (var j = 0; j < 2; j++) {
          final x = right - j;
          final upward = ((right + 1) & 2) == 0;
          final y = upward ? size - 1 - vert : vert;
          if (!isFunction[y][x] && bitIndex < totalBits) {
            modules[y][x] = _bit(codewords[bitIndex >> 3], 7 - (bitIndex & 7));
            bitIndex++;
          }
        }
      }
    }

    // Choose the mask with the lowest penalty (or the forced one).
    var bestMask = forcedMask ?? 0;
    if (forcedMask == null) {
      var bestPenalty = 1 << 30;
      for (var m = 0; m < 8; m++) {
        _applyMask(modules, isFunction, m, size);
        _drawFormat(ecc, m, size, (x, y, d) => modules[y][x] = d);
        final p = _penalty(modules, size);
        if (p < bestPenalty) {
          bestPenalty = p;
          bestMask = m;
        }
        _applyMask(modules, isFunction, m, size); // undo (XOR)
      }
    }
    _applyMask(modules, isFunction, bestMask, size);
    _drawFormat(ecc, bestMask, size, (x, y, d) => modules[y][x] = d);
    return QrCode._(version, ecc, bestMask, modules);
  }

  static void _drawFormat(QrEcc ecc, int mask, int size, void Function(int x, int y, bool dark) set) {
    final data = (ecc.formatBits << 3) | mask;
    var rem = data;
    for (var i = 0; i < 10; i++) {
      rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    }
    final bits = ((data << 10) | rem) ^ 0x5412;
    for (var i = 0; i <= 5; i++) {
      set(8, i, _bit(bits, i));
    }
    set(8, 7, _bit(bits, 6));
    set(8, 8, _bit(bits, 7));
    set(7, 8, _bit(bits, 8));
    for (var i = 9; i < 15; i++) {
      set(14 - i, 8, _bit(bits, i));
    }
    for (var i = 0; i < 8; i++) {
      set(size - 1 - i, 8, _bit(bits, i));
    }
    for (var i = 8; i < 15; i++) {
      set(8, size - 15 + i, _bit(bits, i));
    }
    set(8, size - 8, true);
  }

  static void _drawVersion(int version, int size, void Function(int x, int y, bool dark) set) {
    if (version < 7) return;
    var rem = version;
    for (var i = 0; i < 12; i++) {
      rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    }
    final bits = (version << 12) | rem;
    for (var i = 0; i < 18; i++) {
      final dark = _bit(bits, i);
      final a = size - 11 + i % 3;
      final b = i ~/ 3;
      set(a, b, dark);
      set(b, a, dark);
    }
  }

  static void _applyMask(List<List<bool>> modules, List<List<bool>> isFunction, int mask, int size) {
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        if (isFunction[y][x]) continue;
        final invert = switch (mask) {
          0 => (x + y) % 2 == 0,
          1 => y % 2 == 0,
          2 => x % 3 == 0,
          3 => (x + y) % 3 == 0,
          4 => (x ~/ 3 + y ~/ 2) % 2 == 0,
          5 => x * y % 2 + x * y % 3 == 0,
          6 => (x * y % 2 + x * y % 3) % 2 == 0,
          _ => ((x + y) % 2 + x * y % 3) % 2 == 0,
        };
        if (invert) modules[y][x] = !modules[y][x];
      }
    }
  }

  // --- penalty (ISO 18004 section 8.8.2) ---------------------------------

  static int _penalty(List<List<bool>> m, int size) {
    var result = 0;
    // Rule 1: runs of five or more; Rule 3: finder-like patterns (rows).
    for (var y = 0; y < size; y++) {
      result += _linePenalty([for (var x = 0; x < size; x++) m[y][x]]);
    }
    for (var x = 0; x < size; x++) {
      result += _linePenalty([for (var y = 0; y < size; y++) m[y][x]]);
    }
    // Rule 2: 2x2 blocks.
    for (var y = 0; y < size - 1; y++) {
      for (var x = 0; x < size - 1; x++) {
        final c = m[y][x];
        if (c == m[y][x + 1] && c == m[y + 1][x] && c == m[y + 1][x + 1]) result += 3;
      }
    }
    // Rule 4: dark/light balance.
    var dark = 0;
    for (final row in m) {
      for (final v in row) {
        if (v) dark++;
      }
    }
    final total = size * size;
    final k = ((dark * 20 - total * 10).abs() + total - 1) ~/ total - 1;
    result += k * 10;
    return result;
  }

  static int _linePenalty(List<bool> line) {
    var score = 0;
    var run = 1;
    for (var i = 1; i < line.length; i++) {
      if (line[i] == line[i - 1]) {
        run++;
      } else {
        if (run >= 5) score += 3 + (run - 5);
        run = 1;
      }
    }
    if (run >= 5) score += 3 + (run - 5);
    // 1:1:3:1:1 finder pattern with four light modules on either side.
    const a = [true, false, true, true, true, false, true, false, false, false, false];
    const b = [false, false, false, false, true, false, true, true, true, false, true];
    for (var i = 0; i + 11 <= line.length; i++) {
      var ma = true;
      var mb = true;
      for (var j = 0; j < 11; j++) {
        if (line[i + j] != a[j]) ma = false;
        if (line[i + j] != b[j]) mb = false;
        if (!ma && !mb) break;
      }
      if (ma || mb) score += 40;
    }
    return score;
  }

  // --- tables and Reed-Solomon -------------------------------------------

  static const List<List<int>> _eccPerBlock = [
    // L
    [7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    // M
    [10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
    // Q
    [13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    // H
    [17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
  ];

  static const List<List<int>> _numBlocks = [
    [1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
    [1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
    [1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
    [1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
  ];

  static int _row(QrEcc e) => switch (e) {
        QrEcc.low => 0,
        QrEcc.medium => 1,
        QrEcc.quartile => 2,
        QrEcc.high => 3,
      };

  static int _numRawModules(int ver) {
    var result = (16 * ver + 128) * ver + 64;
    if (ver >= 2) {
      final numAlign = ver ~/ 7 + 2;
      result -= (25 * numAlign - 10) * numAlign - 55;
      if (ver >= 7) result -= 36;
    }
    return result;
  }

  static int _numDataCodewords(int ver, QrEcc ecc) =>
      _numRawModules(ver) ~/ 8 - _eccPerBlock[_row(ecc)][ver - 1] * _numBlocks[_row(ecc)][ver - 1];

  static List<int> _alignmentPositions(int ver) {
    if (ver == 1) return const [];
    final numAlign = ver ~/ 7 + 2;
    final step = ver == 32 ? 26 : (ver * 8 + numAlign * 3 + 5) ~/ (numAlign * 4 - 4) * 2;
    final result = <int>[6];
    final size = ver * 4 + 17;
    for (var pos = size - 7; result.length < numAlign; pos -= step) {
      result.insert(1, pos);
    }
    return result;
  }

  static Uint8List _addEccAndInterleave(Uint8List data, int ver, QrEcc ecc) {
    final numBlocks = _numBlocks[_row(ecc)][ver - 1];
    final blockEccLen = _eccPerBlock[_row(ecc)][ver - 1];
    final rawCodewords = _numRawModules(ver) ~/ 8;
    final numShortBlocks = numBlocks - rawCodewords % numBlocks;
    final shortBlockLen = rawCodewords ~/ numBlocks;

    final divisor = _rsDivisor(blockEccLen);
    final blocks = <Uint8List>[];
    var k = 0;
    for (var i = 0; i < numBlocks; i++) {
      final datLen = shortBlockLen - blockEccLen + (i < numShortBlocks ? 0 : 1);
      final dat = data.sublist(k, k + datLen);
      k += datLen;
      final ecc = _rsRemainder(dat, divisor);
      // Every block is stored at the long-block length; short blocks keep a
      // zero gap that the interleaving below skips.
      final block = Uint8List(shortBlockLen + 1);
      block.setRange(0, dat.length, dat);
      block.setRange(block.length - blockEccLen, block.length, ecc);
      blocks.add(block);
    }
    final result = Uint8List(rawCodewords);
    var r = 0;
    for (var i = 0; i < blocks[0].length; i++) {
      for (var j = 0; j < blocks.length; j++) {
        // Skip the gap in short blocks.
        if (i != shortBlockLen - blockEccLen || j >= numShortBlocks) {
          result[r++] = blocks[j][i];
        }
      }
    }
    return result;
  }

  static Uint8List _rsDivisor(int degree) {
    final result = Uint8List(degree);
    result[degree - 1] = 1;
    var root = 1;
    for (var i = 0; i < degree; i++) {
      for (var j = 0; j < degree; j++) {
        result[j] = _gfMul(result[j], root);
        if (j + 1 < degree) result[j] ^= result[j + 1];
      }
      root = _gfMul(root, 0x02);
    }
    return result;
  }

  static Uint8List _rsRemainder(Uint8List data, Uint8List divisor) {
    final result = Uint8List(divisor.length);
    for (final b in data) {
      final factor = b ^ result[0];
      result.setRange(0, result.length - 1, result, 1);
      result[result.length - 1] = 0;
      for (var i = 0; i < result.length; i++) {
        result[i] ^= _gfMul(divisor[i], factor);
      }
    }
    return result;
  }

  static int _gfMul(int x, int y) {
    var z = 0;
    for (var i = 7; i >= 0; i--) {
      z = (z << 1) ^ ((z >> 7) * 0x11D);
      z ^= ((y >> i) & 1) * x;
    }
    return z & 0xFF;
  }

  static bool _bit(int x, int i) => ((x >> i) & 1) != 0;
}

class _BitBuffer {
  final List<int> _bits = [];

  int get length => _bits.length;

  void append(int value, int count) {
    for (var i = count - 1; i >= 0; i--) {
      _bits.add((value >> i) & 1);
    }
  }

  Uint8List toBytes() {
    final out = Uint8List((_bits.length + 7) ~/ 8);
    for (var i = 0; i < _bits.length; i++) {
      out[i >> 3] |= _bits[i] << (7 - (i & 7));
    }
    return out;
  }
}
