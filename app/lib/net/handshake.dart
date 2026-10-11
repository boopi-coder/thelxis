import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../core/base64url.dart';
import '../core/identity.dart';

/// Transcript strings signed during the handshake and for every SDP
/// (PROTOCOL.md sections 4.1 and 4.2). Kept as pure functions so both ends and
/// the tests use exactly one definition.
String listenerHandshakePayload({
  required String dialerNonce,
  required String listenerNonce,
  required String dialerKey,
}) =>
    'thelxis-hs-v2|listener|$dialerNonce|$listenerNonce|$dialerKey';

String dialerHandshakePayload({
  required String dialerNonce,
  required String listenerNonce,
  required String listenerKey,
}) =>
    'thelxis-hs-v2|dialer|$dialerNonce|$listenerNonce|$listenerKey';

String sdpPayload({
  required String dialerNonce,
  required String listenerNonce,
  required String type,
  required String sdp,
}) =>
    'thelxis-sdp-v2|$dialerNonce|$listenerNonce|$type|$sdp';

/// 32 random bytes, base64url.
String generateNonce([Random? random]) {
  final rng = random ?? Random.secure();
  return b64uEncode(Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256))));
}

/// Random token for TURN-like secrets and session ids' entropy needs.
String randomToken(int bytes, [Random? random]) {
  final rng = random ?? Random.secure();
  return b64uEncode(Uint8List.fromList(List<int>.generate(bytes, (_) => rng.nextInt(256))));
}

Future<String> signPayload(Identity identity, String payload) async =>
    b64uEncode(await identity.sign(utf8.encode(payload)));

/// Verifies a base64url signature over [payload] made by the peer's base64url
/// public key. Any malformed input simply yields false.
Future<bool> verifyPayload({
  required String peerKey,
  required String signature,
  required String payload,
}) async {
  final key = tryB64uDecode(peerKey);
  final sig = tryB64uDecode(signature);
  if (key == null || key.length != 32 || sig == null || sig.length != 64) return false;
  try {
    return await Identity.verify(
      message: utf8.encode(payload),
      signature: sig,
      publicKey: key,
    );
  } on Object {
    return false;
  }
}
