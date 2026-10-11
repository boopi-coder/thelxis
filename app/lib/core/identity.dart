import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';

import 'base64url.dart';
import 'log.dart';
import 'thelxis_id.dart';

const _log = Logger('identity');

/// The device identity: an Ed25519 key pair generated once and kept on disk.
/// The private seed never leaves the device.
class Identity {
  Identity._(this._keyPair, this.publicKey, this._seed);

  final SimpleKeyPairData _keyPair;
  final Uint8List _seed;

  /// Raw 32-byte public key.
  final Uint8List publicKey;

  String get publicKeyB64 => b64uEncode(publicKey);

  /// Thelxis ID (PROTOCOL.md section 1): 16 Crockford base32 characters, no
  /// dashes. Use [formatThelxisId] for display.
  late final String id = thelxisIdFromPublicKey(publicKey);

  String get formattedId => formatThelxisId(id);

  static final _ed25519 = Ed25519();

  static Future<Identity> fromSeed(List<int> seed) async {
    if (seed.length != 32) {
      throw ArgumentError('Ed25519 seed must be 32 bytes');
    }
    final pair = await _ed25519.newKeyPairFromSeed(seed);
    final data = await pair.extract();
    final pub = await pair.extractPublicKey();
    return Identity._(data, Uint8List.fromList(pub.bytes), Uint8List.fromList(seed));
  }

  static Future<Identity> generate() {
    final rng = Random.secure();
    final seed = List<int>.generate(32, (_) => rng.nextInt(256));
    return fromSeed(seed);
  }

  /// Loads `identity.json` from [dir] (default: application support dir) or
  /// creates it with owner-only permissions.
  static Future<Identity> loadOrCreate({Directory? dir}) async {
    final base = dir ?? await getApplicationSupportDirectory();
    final file = File('${base.path}${Platform.pathSeparator}identity.json');
    if (await file.exists()) {
      try {
        final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final seed = tryB64uDecode(json['seed'] as String?);
        if (seed != null && seed.length == 32) {
          final id = await fromSeed(seed);
          final stored = json['public_key'];
          if (stored == null || stored == id.publicKeyB64) return id;
        }
        _log.w('identity.json is inconsistent, regenerating');
      } on Object catch (e) {
        _log.w('could not read identity.json, regenerating', e);
      }
    }
    final id = await generate();
    await base.create(recursive: true);
    await file.writeAsString(jsonEncode({
      'v': 1,
      'seed': b64uEncode(id._seed),
      'public_key': id.publicKeyB64,
    }));
    await _restrict(file);
    return id;
  }

  Future<Uint8List> sign(List<int> message) async {
    final sig = await _ed25519.sign(message, keyPair: _keyPair);
    return Uint8List.fromList(sig.bytes);
  }

  Future<Uint8List> signString(String message) => sign(utf8.encode(message));

  /// Verifies an Ed25519 signature made by [publicKey].
  static Future<bool> verify({
    required List<int> message,
    required List<int> signature,
    required List<int> publicKey,
  }) {
    return _ed25519.verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
  }

  static Future<void> _restrict(File file) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['600', file.path]);
    } on Object catch (e) {
      _log.w('chmod 600 failed', e);
    }
  }
}
