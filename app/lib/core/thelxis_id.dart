import 'package:cryptography/dart.dart' show DartSha256;

/// Crockford base32 alphabet (no I, L, O, U), PROTOCOL.md section 1.
const String kCrockfordAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// Length of a normalised Thelxis ID (80 bits / 5 bits per symbol).
const int kThelxisIdLength = 16;

/// Thelxis ID of a raw 32-byte Ed25519 public key:
/// `CrockfordBase32(SHA-256(key)[0..10])`, 16 characters, no dashes.
String thelxisIdFromPublicKey(List<int> publicKey) {
  final digest = const DartSha256().hashSync(publicKey).bytes;
  return crockfordEncode(digest.sublist(0, 10));
}

/// Encodes whole bytes as Crockford base32 (big-endian bit order). The input
/// length must be a multiple of 5 bytes for an unpadded result.
String crockfordEncode(List<int> bytes) {
  final sb = StringBuffer();
  var buffer = 0;
  var bits = 0;
  for (final b in bytes) {
    buffer = (buffer << 8) | (b & 0xff);
    bits += 8;
    while (bits >= 5) {
      sb.write(kCrockfordAlphabet[(buffer >> (bits - 5)) & 31]);
      bits -= 5;
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) {
    sb.write(kCrockfordAlphabet[(buffer << (5 - bits)) & 31]);
  }
  return sb.toString();
}

/// `K7M2-P9XQ-4TAB-8HDE` for a normalised ID; other input passes through.
String formatThelxisId(String? id) {
  if (id == null || id.isEmpty) return '—';
  if (id.length != kThelxisIdLength) return id;
  return '${id.substring(0, 4)}-${id.substring(4, 8)}-${id.substring(8, 12)}-${id.substring(12)}';
}

/// Tolerant parser: uppercases, drops `-` and spaces, maps `I`/`L` to `1` and
/// `O` to `0`. Returns the normalised 16-character ID or null if the input is
/// not a valid ID.
String? parseThelxisId(String? input) {
  if (input == null) return null;
  final cleaned = input
      .toUpperCase()
      .replaceAll(RegExp(r'[-\s]'), '')
      .replaceAll('I', '1')
      .replaceAll('L', '1')
      .replaceAll('O', '0');
  if (cleaned.length != kThelxisIdLength) return null;
  for (final unit in cleaned.codeUnits) {
    if (!kCrockfordAlphabet.contains(String.fromCharCode(unit))) return null;
  }
  return cleaned;
}
