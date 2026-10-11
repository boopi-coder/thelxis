import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/settings.dart';

/// One finished session in the local history.
class SessionRecord {
  const SessionRecord({
    required this.sid,
    required this.incoming,
    required this.peerName,
    required this.peerId,
    required this.peerOs,
    required this.startedAt,
    required this.durationSeconds,
    required this.path,
    required this.reason,
  });

  final String sid;

  /// True when this device was controlled.
  final bool incoming;
  final String peerName;
  final String peerId;
  final String peerOs;
  final DateTime startedAt;
  final int durationSeconds;
  final String path;
  final String reason;

  Map<String, dynamic> toJson() => {
        'sid': sid,
        'incoming': incoming,
        'name': peerName,
        'id': peerId,
        'os': peerOs,
        'started': startedAt.millisecondsSinceEpoch ~/ 1000,
        'duration': durationSeconds,
        'path': path,
        'reason': reason,
      };

  static SessionRecord? fromJson(Object? json) {
    if (json is! Map || json['sid'] is! String) return null;
    return SessionRecord(
      sid: json['sid'] as String,
      incoming: json['incoming'] == true,
      peerName: json['name'] is String ? json['name'] as String : 'Unknown',
      peerId: json['id'] is String ? json['id'] as String : '',
      peerOs: json['os'] is String ? json['os'] as String : 'unknown',
      startedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['started'] is num ? (json['started'] as num).toInt() : 0) * 1000,
      ),
      durationSeconds: json['duration'] is num ? (json['duration'] as num).toInt() : 0,
      path: json['path'] is String ? json['path'] as String : '—',
      reason: json['reason'] is String ? json['reason'] as String : 'user',
    );
  }
}

/// Local-only log of finished sessions (last 50), persisted in settings.
class SessionHistory extends ChangeNotifier {
  SessionHistory(this._settings) {
    _load();
  }

  static const int maxEntries = 50;

  final AppSettings _settings;
  final List<SessionRecord> _records = [];

  /// Newest first.
  List<SessionRecord> get records => List.unmodifiable(_records);

  Future<void> add(SessionRecord r) async {
    _records.insert(0, r);
    if (_records.length > maxEntries) _records.removeRange(maxEntries, _records.length);
    notifyListeners();
    await _settings.setHistoryJson(jsonEncode(_records.map((e) => e.toJson()).toList()));
  }

  Future<void> clear() async {
    _records.clear();
    notifyListeners();
    await _settings.setHistoryJson('[]');
  }

  void _load() {
    final raw = _settings.historyJson;
    if (raw == null) return;
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        for (final item in list) {
          final r = SessionRecord.fromJson(item);
          if (r != null) _records.add(r);
        }
      }
    } on FormatException {
      // Corrupt history is dropped rather than blocking startup.
    }
  }
}
