import 'dart:convert';
import 'dart:typed_data';

import '../core/base64url.dart';
import 'manifest.dart';
import 'update_exception.dart';
import 'update_http.dart';
import 'update_trust.dart';

/// Fetches [url] (at most `maxBytes`). Injectable for tests.
typedef BytesFetcher = Future<Uint8List> Function(Uri url, {required int maxBytes});

/// Downloads `update.json` and `update.json.sig`, verifies the Ed25519
/// signature over the raw manifest bytes and only then parses it
/// (PROTOCOL.md section 10). There is no unsigned fallback.
class ManifestLoader {
  ManifestLoader({
    UpdateHttp? http,
    BytesFetcher? fetch,
    SignatureVerifier? verifier,
    Uri? manifestUrl,
    Uri? signatureUrl,
  })  : _fetch = fetch ?? _httpFetcher(http ?? UpdateHttp()),
        _verify = verifier ?? ed25519Verifier(),
        _manifestUrl = manifestUrl ?? Uri.parse(UpdateTrust.manifestUrl),
        _signatureUrl = signatureUrl ?? Uri.parse(UpdateTrust.signatureUrl);

  final BytesFetcher _fetch;
  final SignatureVerifier _verify;
  final Uri _manifestUrl;
  final Uri _signatureUrl;

  static BytesFetcher _httpFetcher(UpdateHttp http) =>
      (url, {required maxBytes}) => http.getBytes(url, maxBytes: maxBytes);

  Future<UpdateManifest> load() async {
    final results = await Future.wait<Uint8List>([
      _fetch(_manifestUrl, maxBytes: kMaxManifestBytes),
      _fetchSignature(),
    ]);
    final manifestBytes = results[0];
    final signature = _decodeSignature(results[1]);
    if (!await _verify(manifestBytes, signature)) {
      throw const UpdateException(
        UpdateErrorKind.signatureInvalid,
        'manifest signature does not verify against the embedded release key',
      );
    }
    return UpdateManifest.parse(manifestBytes);
  }

  Future<Uint8List> _fetchSignature() async {
    try {
      return await _fetch(_signatureUrl, maxBytes: 1024);
    } on UpdateException catch (e) {
      if (e.kind == UpdateErrorKind.http && e.status == 404) {
        throw const UpdateException(UpdateErrorKind.signatureMissing, 'update.json.sig not found');
      }
      rethrow;
    }
  }

  /// `update.json.sig` is base64url(raw 64-byte signature), maybe followed by
  /// a newline.
  static Uint8List _decodeSignature(Uint8List raw) {
    try {
      final bytes = b64uDecode(utf8.decode(raw).trim());
      if (bytes.length == 64) return bytes;
    } on FormatException {
      // fall through to the shared error
    }
    throw const UpdateException(UpdateErrorKind.signatureInvalid, 'malformed signature file');
  }
}
