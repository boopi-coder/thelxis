import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'base64url.dart';

/// PBKDF2 iteration count fixed by PROTOCOL.md section 5.1.
const int kPasswordIterations = 60000;

/// Salt for the password key: `thelxis-pw-v1:<host ID without dashes>`.
List<int> passwordSalt(String hostId) => utf8.encode('thelxis-pw-v1:$hostId');

/// PBKDF2-HMAC-SHA256(password, salt, 60000, 32). Pure-Dart PBKDF2 over 60k
/// iterations is CPU heavy, so this always runs on a worker isolate and never
/// blocks the UI isolate.
Future<Uint8List> derivePasswordKey(String password, String hostId) {
  return Isolate.run(() => derivePasswordKeySync(password, hostId));
}

/// Same as [derivePasswordKey] but runs on the calling isolate. Exposed for
/// tests and for use inside an already-spawned isolate.
Future<Uint8List> derivePasswordKeySync(String password, String hostId) async {
  final pbkdf2 = Pbkdf2.hmacSha256(iterations: kPasswordIterations, bits: 256);
  final key = await pbkdf2.deriveKeyFromPassword(
    password: password,
    nonce: passwordSalt(hostId),
  );
  return Uint8List.fromList(await key.extractBytes());
}

/// The two DTLS fingerprints sorted ascending as strings, per section 5.1.
List<String> sortedFingerprints(String a, String b) {
  return a.compareTo(b) <= 0 ? [a, b] : [b, a];
}

/// `HMAC-SHA256(key, "thelxis-auth-v1|" + nonce + "|" + fp_a + "|" + fp_b)`.
Future<Uint8List> computePasswordProof({
  required List<int> key,
  required String nonce,
  required String fingerprintA,
  required String fingerprintB,
}) async {
  final fps = sortedFingerprints(fingerprintA, fingerprintB);
  final msg = utf8.encode('thelxis-auth-v1|$nonce|${fps[0]}|${fps[1]}');
  final mac = await Hmac.sha256().calculateMac(msg, secretKey: SecretKey(key));
  return Uint8List.fromList(mac.bytes);
}

/// base64url form of [computePasswordProof], as sent on the wire.
Future<String> computePasswordProofB64({
  required List<int> key,
  required String nonce,
  required String fingerprintA,
  required String fingerprintB,
}) async {
  return b64uEncode(await computePasswordProof(
    key: key,
    nonce: nonce,
    fingerprintA: fingerprintA,
    fingerprintB: fingerprintB,
  ));
}

/// Checks a received [proof] against the expected one in constant time.
Future<bool> verifyPasswordProof({
  required List<int> key,
  required String nonce,
  required String fingerprintA,
  required String fingerprintB,
  required String proof,
}) async {
  final received = tryB64uDecode(proof);
  if (received == null) return false;
  final expected = await computePasswordProof(
    key: key,
    nonce: nonce,
    fingerprintA: fingerprintA,
    fingerprintB: fingerprintB,
  );
  return constantTimeEquals(received, expected);
}
