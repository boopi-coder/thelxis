import 'dart:math';

/// Lowercase letters and digits without the look-alikes `i l o 0 1`.
const String kOneTimeAlphabet = 'abcdefghjkmnpqrstuvwxyz23456789';

const int kOneTimePasswordLength = 8;

/// A fresh one-time password (8 chars, ~39.6 bits) from a CSPRNG.
String generateOneTimePassword({Random? random, int length = kOneTimePasswordLength}) {
  final rng = random ?? Random.secure();
  final sb = StringBuffer();
  for (var i = 0; i < length; i++) {
    sb.write(kOneTimeAlphabet[rng.nextInt(kOneTimeAlphabet.length)]);
  }
  return sb.toString();
}
