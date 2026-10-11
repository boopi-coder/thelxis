// One-time TURN credentials (PROTOCOL.md §4.1 / §4.3).
//
// A grant is valid until its TTL runs out, or until 60 s after it was revoked
// (the grace lets the final ICE/DTLS teardown packets still flow).

import 'dart:math';
import 'dart:typed_data';

import '../../core/base64url.dart';
import 'stun_crypto.dart';

typedef Clock = DateTime Function();

/// Grace period between a session ending and its credentials dying.
const Duration turnRevokeGrace = Duration(seconds: 60);

class TurnGrantRecord {
  TurnGrantRecord({
    required this.username,
    required this.password,
    required this.expiresAt,
  });

  final String username;
  final String password;
  final DateTime expiresAt;
  DateTime? revokedAt;

  Uint8List? _key;
  String? _keyRealm;

  /// MD5(username:realm:password), cached because every request needs it.
  Uint8List longTermKeyFor(String realm) {
    if (_key == null || _keyRealm != realm) {
      _key = longTermKey(
          username.codeUnits, realm.codeUnits, password.codeUnits);
      _keyRealm = realm;
    }
    return _key!;
  }
}

class TurnGrantStore {
  TurnGrantStore({Clock? clock}) : _clock = clock ?? DateTime.now;

  final Clock _clock;
  final Map<String, TurnGrantRecord> _byUsername = {};
  final Random _random = Random.secure();

  int get length => _byUsername.length;

  List<int> _randomBytes(int n) =>
      List<int>.generate(n, (_) => _random.nextInt(256));

  TurnGrantRecord issue({required Duration ttl}) {
    purge();
    final record = TurnGrantRecord(
      username: b64uEncode(_randomBytes(16)),
      password: b64uEncode(_randomBytes(24)),
      expiresAt: _clock().add(ttl),
    );
    _byUsername[record.username] = record;
    return record;
  }

  /// Marks the grant as ended; it keeps working for [turnRevokeGrace].
  void revoke(String username) {
    final record = _byUsername[username];
    if (record != null) record.revokedAt ??= _clock();
  }

  bool isValid(TurnGrantRecord record) {
    final now = _clock();
    if (!now.isBefore(record.expiresAt)) return false;
    final revoked = record.revokedAt;
    return revoked == null || now.isBefore(revoked.add(turnRevokeGrace));
  }

  TurnGrantRecord? lookupValid(String username) {
    final record = _byUsername[username];
    return record != null && isValid(record) ? record : null;
  }

  void purge() => _byUsername.removeWhere((_, r) => !isValid(r));

  void clear() => _byUsername.clear();
}
