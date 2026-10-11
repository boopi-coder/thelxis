// Hash primitives needed by STUN (RFC 5389): MD5 for the long-term credential
// key, HMAC-SHA1 for MESSAGE-INTEGRITY and CRC-32 for FINGERPRINT.
//
// MD5 is not offered by package:cryptography, so it is implemented here. It is
// used only because RFC 5389 §15.4 mandates it for the key derivation; nothing
// else in Thelxis relies on it.

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

final _hmacSha1 = Hmac.sha1().toSync();

/// HMAC-SHA1 (20 bytes), synchronous so it can run inside packet handlers.
Uint8List hmacSha1(List<int> key, List<int> message) {
  final mac = _hmacSha1.calculateMacSync(
    message,
    secretKeyData: SecretKeyData(key),
    nonce: const <int>[],
  );
  return Uint8List.fromList(mac.bytes);
}

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[n] = c;
  }
  return table;
}();

/// Standard CRC-32 (IEEE 802.3, as used by zlib).
int crc32(List<int> data, [int start = 0, int? end]) {
  var c = 0xFFFFFFFF;
  final stop = end ?? data.length;
  for (var i = start; i < stop; i++) {
    c = _crcTable[(c ^ data[i]) & 0xFF] ^ (c >>> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// STUN FINGERPRINT value: CRC-32 XOR 0x5354554e ("STUN").
int stunFingerprint(List<int> data, int end) =>
    (crc32(data, 0, end) ^ 0x5354554e) & 0xFFFFFFFF;

const List<int> _md5Shifts = [
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, //
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
];

// K[i] = floor(2^32 * abs(sin(i + 1))) per RFC 1321.
const List<int> _md5K = [
  0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, //
  0xa8304613, 0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
  0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340,
  0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
  0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8,
  0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
  0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa,
  0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
  0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92,
  0xffeff47d, 0x85845dd1, 0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
  0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
];

/// MD5 digest (16 bytes) of [message] (RFC 1321).
Uint8List md5(List<int> message) {
  final length = message.length;
  final padded = (length + 9 + 63) ~/ 64 * 64;
  final buffer = Uint8List(padded);
  buffer.setRange(0, length, message);
  buffer[length] = 0x80;
  final view = ByteData.sublistView(buffer);
  final bitLength = length * 8;
  view.setUint32(padded - 8, bitLength & 0xFFFFFFFF, Endian.little);
  view.setUint32(padded - 4, (bitLength >>> 32) & 0xFFFFFFFF, Endian.little);

  var a0 = 0x67452301;
  var b0 = 0xefcdab89;
  var c0 = 0x98badcfe;
  var d0 = 0x10325476;
  final words = Uint32List(16);

  for (var offset = 0; offset < padded; offset += 64) {
    for (var i = 0; i < 16; i++) {
      words[i] = view.getUint32(offset + i * 4, Endian.little);
    }
    var a = a0, b = b0, c = c0, d = d0;
    for (var i = 0; i < 64; i++) {
      int f;
      int g;
      if (i < 16) {
        f = (b & c) | (~b & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | (~d & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | (~d & 0xFFFFFFFF));
        g = (7 * i) % 16;
      }
      f = (f + a + _md5K[i] + words[g]) & 0xFFFFFFFF;
      a = d;
      d = c;
      c = b;
      final s = _md5Shifts[i];
      b = (b + (((f << s) | (f >>> (32 - s))) & 0xFFFFFFFF)) & 0xFFFFFFFF;
    }
    a0 = (a0 + a) & 0xFFFFFFFF;
    b0 = (b0 + b) & 0xFFFFFFFF;
    c0 = (c0 + c) & 0xFFFFFFFF;
    d0 = (d0 + d) & 0xFFFFFFFF;
  }

  final out = Uint8List(16);
  final outView = ByteData.sublistView(out);
  outView.setUint32(0, a0, Endian.little);
  outView.setUint32(4, b0, Endian.little);
  outView.setUint32(8, c0, Endian.little);
  outView.setUint32(12, d0, Endian.little);
  return out;
}

/// Long-term credential key: MD5(username ":" realm ":" password), RFC 5389
/// §15.4. SASLprep is not applied: Thelxis credentials are base64url ASCII.
Uint8List longTermKey(
  List<int> username,
  List<int> realm,
  List<int> password,
) => md5([...username, 0x3a, ...realm, 0x3a, ...password]);
