import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/base64url.dart';
import '../core/identity.dart';
import 'handshake.dart';
import 'peer_identity.dart';

/// Connection codes (PROTOCOL.md section 12): two short texts the users swap
/// over any channel. `TX1.` is the host's signed WebRTC offer, `TX2.` the
/// viewer's signed answer; together with public STUN they let two devices that
/// cannot accept connections punch through their NATs.
///
/// Wire form: `"TX1." + base64url(rawDeflate(utf8(JSON)))`.

/// Larger codes are rejected before they are inflated.
const int kMaxCodeChars = 16 * 1024;

/// Hard limit for the inflated JSON (a deflate bomb must not eat memory).
const int kMaxCodeJsonBytes = 64 * 1024;

/// How long an offer code is valid.
const Duration kCodeLifetime = Duration(minutes: 10);

const String kOfferPrefix = 'TX1.';
const String kAnswerPrefix = 'TX2.';

enum CodeError {
  /// Not a code at all, or damaged (copy/paste cut it, typo).
  malformed,

  /// Over [kMaxCodeChars].
  tooLarge,

  /// A newer code version than this app understands.
  unsupported,

  /// The offer's `exp` has passed (or is absurdly far away).
  expired,

  /// The signature does not verify: tampered, or made by another key.
  badSignature,

  /// The answer belongs to a different offer, or the code is our own.
  mismatch,
}

class CodeException implements Exception {
  const CodeException(this.error, [this.detail = '']);

  final CodeError error;
  final String detail;

  @override
  String toString() => 'CodeException(${error.name}${detail.isEmpty ? '' : ': $detail'})';
}

/// A verified `TX1.` code: the host and its offer.
class OfferCode {
  const OfferCode({
    required this.key,
    required this.name,
    required this.os,
    required this.nonce,
    required this.exp,
    required this.sdp,
    required this.sig,
  });

  final String key;
  final String name;
  final String os;

  /// The host's nonce `nH`.
  final String nonce;

  /// Expiry, Unix seconds.
  final int exp;
  final String sdp;
  final String sig;

  PeerIdentity get peer => PeerIdentity.fromHello(
        key: key,
        name: name,
        os: os,
        app: '',
        addresses: const [],
      )!;

  DateTime get expiresAt => DateTime.fromMillisecondsSinceEpoch(exp * 1000);
}

/// A verified `TX2.` code: the viewer and its answer.
class AnswerCode {
  const AnswerCode({
    required this.key,
    required this.name,
    required this.os,
    required this.nonce,
    required this.sdp,
    required this.sig,
  });

  final String key;
  final String name;
  final String os;

  /// The viewer's nonce `nV`.
  final String nonce;
  final String sdp;
  final String sig;

  PeerIdentity get peer => PeerIdentity.fromHello(
        key: key,
        name: name,
        os: os,
        app: '',
        addresses: const [],
      )!;
}

/// Whether [text] looks like a connection code (either kind), whatever its
/// state; used to route pasted input.
bool looksLikeConnectionCode(String text) {
  final t = text.trimLeft();
  return t.startsWith(kOfferPrefix) || t.startsWith(kAnswerPrefix);
}

String offerSignaturePayload({required String nonce, required int exp, required String sdp}) =>
    'thelxis-code-v1|offer|$nonce|$exp|$sdp';

String answerSignaturePayload({required String hostNonce, required String viewerNonce, required String sdp}) =>
    'thelxis-code-v1|answer|$hostNonce|$viewerNonce|$sdp';

/// Builds the `TX1.` code for [sdp] (a complete offer, ICE gathering done).
Future<String> buildOfferCode({
  required Identity identity,
  required String name,
  required String os,
  required String nonce,
  required int exp,
  required String sdp,
}) async {
  final sig = await signPayload(identity, offerSignaturePayload(nonce: nonce, exp: exp, sdp: sdp));
  return kOfferPrefix +
      _pack({
        'v': 1,
        'k': identity.publicKeyB64,
        'n': name,
        'os': os,
        'nonce': nonce,
        'exp': exp,
        'sdp': sdp,
        'sig': sig,
      });
}

/// Parses and verifies a `TX1.` code. [now] defaults to the clock.
Future<OfferCode> parseOfferCode(String text, {DateTime? now, String? ownKey}) async {
  final j = _unpack(text, kOfferPrefix);
  final key = _str(j, 'k');
  final nonce = _str(j, 'nonce');
  final sdp = _str(j, 'sdp');
  final sig = _str(j, 'sig');
  final exp = j['exp'];
  if (exp is! int) throw const CodeException(CodeError.malformed, 'exp');
  _checkKeyAndNonce(key, nonce);
  if (ownKey != null && key == ownKey) {
    throw const CodeException(CodeError.mismatch, 'own code');
  }
  final nowSec = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  if (exp < nowSec) throw const CodeException(CodeError.expired);
  if (exp > nowSec + kCodeLifetime.inSeconds + 60) {
    throw const CodeException(CodeError.expired, 'expiry too far ahead');
  }
  final ok = await verifyPayload(
    peerKey: key,
    signature: sig,
    payload: offerSignaturePayload(nonce: nonce, exp: exp, sdp: sdp),
  );
  if (!ok) throw const CodeException(CodeError.badSignature);
  return OfferCode(
    key: key,
    name: _clip(_opt(j, 'n', 'Unknown'), 64),
    os: _clip(_opt(j, 'os', 'unknown'), 16),
    nonce: nonce,
    exp: exp,
    sdp: sdp,
    sig: sig,
  );
}

/// Builds the `TX2.` code answering the offer with host nonce [hostNonce].
Future<String> buildAnswerCode({
  required Identity identity,
  required String name,
  required String os,
  required String hostNonce,
  required String viewerNonce,
  required String sdp,
}) async {
  final sig = await signPayload(
    identity,
    answerSignaturePayload(hostNonce: hostNonce, viewerNonce: viewerNonce, sdp: sdp),
  );
  return kAnswerPrefix +
      _pack({
        'v': 1,
        'k': identity.publicKeyB64,
        'n': name,
        'os': os,
        'nonce': viewerNonce,
        'sdp': sdp,
        'sig': sig,
      });
}

/// Parses a `TX2.` code and verifies that it answers the offer with
/// [hostNonce].
Future<AnswerCode> parseAnswerCode(String text, {required String hostNonce, String? ownKey}) async {
  final j = _unpack(text, kAnswerPrefix);
  final key = _str(j, 'k');
  final nonce = _str(j, 'nonce');
  final sdp = _str(j, 'sdp');
  final sig = _str(j, 'sig');
  _checkKeyAndNonce(key, nonce);
  if (ownKey != null && key == ownKey) {
    throw const CodeException(CodeError.mismatch, 'own code');
  }
  final ok = await verifyPayload(
    peerKey: key,
    signature: sig,
    payload: answerSignaturePayload(hostNonce: hostNonce, viewerNonce: nonce, sdp: sdp),
  );
  // The host nonce is in the signed text, so an answer made for another
  // offer fails here too.
  if (!ok) throw const CodeException(CodeError.badSignature);
  return AnswerCode(
    key: key,
    name: _clip(_opt(j, 'n', 'Unknown'), 64),
    os: _clip(_opt(j, 'os', 'unknown'), 16),
    nonce: nonce,
    sdp: sdp,
    sig: sig,
  );
}

// --- encoding ---------------------------------------------------------------

String _pack(Map<String, Object?> json) {
  final raw = utf8.encode(jsonEncode(json));
  return b64uEncode(ZLibCodec(raw: true, level: 9).encode(raw));
}

Map<String, dynamic> _unpack(String text, String prefix) {
  // Chat apps wrap long lines; whitespace is never part of a code.
  final t = text.replaceAll(RegExp(r'\s+'), '');
  if (t.length > kMaxCodeChars) throw const CodeException(CodeError.tooLarge);
  if (!t.startsWith(prefix)) throw const CodeException(CodeError.malformed, 'prefix');
  final packed = tryB64uDecode(t.substring(prefix.length));
  if (packed == null) throw const CodeException(CodeError.malformed, 'base64');
  final Uint8List raw;
  try {
    raw = _inflateLimited(packed, kMaxCodeJsonBytes);
  } on CodeException {
    rethrow;
  } on Object {
    // Bad data surfaces as a FormatException or a filter error, depending on
    // the platform's zlib.
    throw const CodeException(CodeError.malformed, 'deflate');
  }
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(raw));
  } on FormatException {
    throw const CodeException(CodeError.malformed, 'json');
  }
  if (json is! Map<String, dynamic>) throw const CodeException(CodeError.malformed, 'json');
  final v = json['v'];
  if (v is! int) throw const CodeException(CodeError.malformed, 'v');
  if (v != 1) throw const CodeException(CodeError.unsupported);
  return json;
}

/// Inflates raw deflate data, giving up as soon as the output exceeds [limit].
Uint8List _inflateLimited(Uint8List input, int limit) {
  final out = BytesBuilder(copy: false);
  var total = 0;
  final decoder = ZLibDecoder(raw: true).startChunkedConversion(_LimitSink((chunk) {
    total += chunk.length;
    if (total > limit) throw const CodeException(CodeError.tooLarge, 'inflated size');
    out.add(chunk);
  }));
  const step = 512;
  for (var i = 0; i < input.length; i += step) {
    decoder.addSlice(input, i, i + step > input.length ? input.length : i + step, false);
  }
  decoder.close();
  return out.takeBytes();
}

class _LimitSink extends ByteConversionSinkBase {
  _LimitSink(this._onChunk);

  final void Function(List<int> chunk) _onChunk;

  @override
  void add(List<int> chunk) => _onChunk(chunk);

  @override
  void close() {}
}

String _str(Map<String, dynamic> j, String key) {
  final v = j[key];
  if (v is! String || v.isEmpty) throw CodeException(CodeError.malformed, key);
  return v;
}

String _opt(Map<String, dynamic> j, String key, String fallback) {
  final v = j[key];
  return v is String && v.isNotEmpty ? v : fallback;
}

String _clip(String s, int max) => s.length <= max ? s : s.substring(0, max);

void _checkKeyAndNonce(String key, String nonce) {
  final raw = tryB64uDecode(key);
  if (raw == null || raw.length != 32) throw const CodeException(CodeError.malformed, 'k');
  if (nonce.length < 16 || nonce.length > 128) {
    throw const CodeException(CodeError.malformed, 'nonce');
  }
}
