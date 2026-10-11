import 'dart:convert';
import 'dart:typed_data';

/// base64url without padding (RFC 4648 section 5), as used by PROTOCOL.md.
String b64uEncode(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// Decodes base64url with or without padding. Throws [FormatException] on
/// malformed input.
Uint8List b64uDecode(String input) {
  final padded = input.padRight((input.length + 3) ~/ 4 * 4, '=');
  return Uint8List.fromList(base64Url.decode(padded));
}

/// Like [b64uDecode] but returns null instead of throwing.
Uint8List? tryB64uDecode(String? input) {
  if (input == null || input.isEmpty) return null;
  try {
    return b64uDecode(input);
  } on FormatException {
    return null;
  }
}

/// Constant-time equality for secrets such as password proofs.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
