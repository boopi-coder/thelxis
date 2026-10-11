import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/models.dart';
import 'thelxis_id.dart';

/// A device allowed to connect without a password or prompt, like an SSH
/// authorized key (PROTOCOL.md section 6.1, method `trusted`).
class TrustedDevice {
  const TrustedDevice({
    required this.key,
    required this.id,
    required this.name,
    required this.permissions,
    required this.added,
  });

  /// base64url public key; the identity that is trusted.
  final String key;
  final String id;
  final String name;
  final Permissions permissions;
  final DateTime added;

  String get formattedId => formatThelxisId(id);

  TrustedDevice copyWith({Permissions? permissions, String? name}) => TrustedDevice(
        key: key,
        id: id,
        name: name ?? this.name,
        permissions: permissions ?? this.permissions,
        added: added,
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'id': id,
        'name': name,
        'permissions': permissions.toJson(),
        'added': added.millisecondsSinceEpoch ~/ 1000,
      };

  static TrustedDevice? fromJson(Object? json) {
    if (json is! Map) return null;
    final key = json['key'];
    final id = json['id'];
    if (key is! String || id is! String) return null;
    return TrustedDevice(
      key: key,
      id: id,
      name: json['name'] is String ? json['name'] as String : 'Unknown',
      permissions: Permissions.fromJson(json['permissions']),
      added: json['added'] is num
          ? DateTime.fromMillisecondsSinceEpoch((json['added'] as num).toInt() * 1000)
          : DateTime.now(),
    );
  }
}

/// Read-only view used by the host authenticator.
abstract class TrustLookup {
  bool isTrusted(String key);
  Permissions? permissionsFor(String key);
}

class TrustedDevices extends ChangeNotifier implements TrustLookup {
  TrustedDevices(this._prefs) {
    _load();
  }

  static const _storeKey = 'trusted_devices_v2';

  final SharedPreferences _prefs;
  final Map<String, TrustedDevice> _byKey = {};

  List<TrustedDevice> get devices =>
      _byKey.values.toList()..sort((a, b) => b.added.compareTo(a.added));

  @override
  bool isTrusted(String key) => _byKey.containsKey(key);

  @override
  Permissions? permissionsFor(String key) => _byKey[key]?.permissions;

  TrustedDevice? get(String key) => _byKey[key];

  Future<void> add({
    required String key,
    required String id,
    required String name,
    required Permissions permissions,
  }) async {
    final existing = _byKey[key];
    _byKey[key] = TrustedDevice(
      key: key,
      id: id,
      name: name,
      permissions: permissions,
      added: existing?.added ?? DateTime.now(),
    );
    await _save();
  }

  Future<void> updatePermissions(String key, Permissions permissions) async {
    final d = _byKey[key];
    if (d == null) return;
    _byKey[key] = d.copyWith(permissions: permissions);
    await _save();
  }

  Future<void> revoke(String key) async {
    if (_byKey.remove(key) != null) await _save();
  }

  void _load() {
    final raw = _prefs.getString(_storeKey);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        for (final item in list) {
          final d = TrustedDevice.fromJson(item);
          if (d != null) _byKey[d.key] = d;
        }
      }
    } on FormatException {
      // Treat corrupt data as empty: failing closed (nobody trusted) is safe.
    }
  }

  Future<void> _save() async {
    await _prefs.setString(_storeKey, jsonEncode(_byKey.values.map((d) => d.toJson()).toList()));
    notifyListeners();
  }
}
