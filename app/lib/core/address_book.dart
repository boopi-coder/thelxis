import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../net/peer_identity.dart';
import 'thelxis_id.dart';

/// A remembered device (PROTOCOL.md section 3: the ID verifies, addresses
/// locate). Persisted locally; importable/exportable as JSON.
class AddressBookEntry {
  AddressBookEntry({
    required this.id,
    required this.name,
    this.key,
    this.os = 'unknown',
    List<String>? addresses,
    List<String>? gateways,
    this.alias = '',
    this.favorite = false,
    List<String>? tags,
    this.notes = '',
    this.lastSeen,
    this.lastConnected,
  })  : addresses = addresses ?? [],
        gateways = gateways ?? [],
        tags = tags ?? [];

  /// Normalised 16-character Thelxis ID.
  final String id;

  /// Name the device announced.
  String name;
  String? key;
  String os;
  List<String> addresses;

  /// Office gateways (`host:port`) that can reach this device from outside
  /// (PROTOCOL.md section 11), from invite links.
  List<String> gateways;

  /// User-chosen label; wins over [name] in the UI.
  String alias;
  bool favorite;
  List<String> tags;
  String notes;
  DateTime? lastSeen;
  DateTime? lastConnected;

  String get displayName => alias.trim().isNotEmpty ? alias.trim() : name;

  String get formattedId => formatThelxisId(id);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (key != null) 'key': key,
        'os': os,
        'addresses': addresses,
        if (gateways.isNotEmpty) 'gateways': gateways,
        if (alias.isNotEmpty) 'alias': alias,
        'favorite': favorite,
        'tags': tags,
        if (notes.isNotEmpty) 'notes': notes,
        if (lastSeen != null) 'last_seen': lastSeen!.millisecondsSinceEpoch ~/ 1000,
        if (lastConnected != null)
          'last_connected': lastConnected!.millisecondsSinceEpoch ~/ 1000,
      };

  static AddressBookEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = parseThelxisId(json['id'] as String?);
    if (id == null) return null;
    List<String> strings(Object? v) =>
        v is List ? v.whereType<String>().toList() : <String>[];
    DateTime? time(Object? v) =>
        v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000) : null;
    return AddressBookEntry(
      id: id,
      name: json['name'] is String ? json['name'] as String : 'Unknown',
      key: json['key'] is String ? json['key'] as String : null,
      os: json['os'] is String ? json['os'] as String : 'unknown',
      addresses: strings(json['addresses']),
      gateways: strings(json['gateways']),
      alias: json['alias'] is String ? json['alias'] as String : '',
      favorite: json['favorite'] == true,
      tags: strings(json['tags']),
      notes: json['notes'] is String ? json['notes'] as String : '',
      lastSeen: time(json['last_seen']),
      lastConnected: time(json['last_connected']),
    );
  }
}

class AddressBook extends ChangeNotifier {
  AddressBook(this._prefs) {
    _load();
  }

  static const _key = 'address_book_v2';
  static const _maxAddresses = 8;

  final SharedPreferences _prefs;
  final Map<String, AddressBookEntry> _entries = {};

  /// Favorites first, then most recently used.
  List<AddressBookEntry> get entries {
    final list = _entries.values.toList();
    list.sort((a, b) {
      if (a.favorite != b.favorite) return a.favorite ? -1 : 1;
      final ta = a.lastConnected ?? a.lastSeen;
      final tb = b.lastConnected ?? b.lastSeen;
      if (ta != null && tb != null) return tb.compareTo(ta);
      if (ta != null) return -1;
      if (tb != null) return 1;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    return list;
  }

  AddressBookEntry? byId(String id) => _entries[id];

  /// Entries we actually connected to, newest first.
  List<AddressBookEntry> recents({int limit = 6}) {
    final list = _entries.values.where((e) => e.lastConnected != null).toList()
      ..sort((a, b) => b.lastConnected!.compareTo(a.lastConnected!));
    return list.take(limit).toList();
  }

  /// Records a verified peer. New addresses go first so the most recent
  /// working one is tried first next time.
  Future<AddressBookEntry> upsertPeer(
    PeerIdentity peer, {
    String? reachedAt,
    bool connected = false,
    List<String> gateways = const [],
  }) async {
    final entry = _entries.putIfAbsent(
      peer.id,
      () => AddressBookEntry(id: peer.id, name: peer.name),
    );
    entry
      ..name = peer.name
      ..key = peer.key
      ..os = peer.os
      ..lastSeen = DateTime.now();
    if (connected) entry.lastConnected = DateTime.now();
    final fresh = [?reachedAt, ...peer.addresses];
    _mergeAddresses(entry, fresh);
    if (gateways.isNotEmpty) {
      entry.gateways = {...gateways, ...entry.gateways}.take(_maxAddresses).toList();
    }
    await _save();
    return entry;
  }

  /// Adds or replaces a user-entered entry (without a verified key yet).
  Future<AddressBookEntry> addManual({
    required String id,
    required String name,
    List<String> addresses = const [],
  }) async {
    final entry = _entries.putIfAbsent(id, () => AddressBookEntry(id: id, name: name));
    if (name.trim().isNotEmpty) entry.name = name.trim();
    _mergeAddresses(entry, addresses);
    await _save();
    return entry;
  }

  Future<void> update(
    String id, {
    String? alias,
    bool? favorite,
    List<String>? tags,
    String? notes,
    List<String>? addresses,
  }) async {
    final e = _entries[id];
    if (e == null) return;
    if (alias != null) e.alias = alias.trim();
    if (favorite != null) e.favorite = favorite;
    if (tags != null) e.tags = tags.map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
    if (notes != null) e.notes = notes;
    if (addresses != null) e.addresses = addresses.take(_maxAddresses).toList();
    await _save();
  }

  Future<void> remove(String id) async {
    if (_entries.remove(id) != null) await _save();
  }

  /// Pretty JSON for backup / fleet deployment.
  String exportJson() => const JsonEncoder.withIndent('  ').convert({
        'format': 'thelxis-address-book',
        'v': 1,
        'entries': entries.map((e) => e.toJson()).toList(),
      });

  /// Merges an export into this book; returns the number of entries read.
  /// Throws [FormatException] when the text is not an address book export.
  Future<int> importJson(String text) async {
    final Object? decoded = jsonDecode(text);
    if (decoded is! Map || decoded['format'] != 'thelxis-address-book') {
      throw const FormatException('Not a Thelxis address book export');
    }
    final list = decoded['entries'];
    if (list is! List) throw const FormatException('Missing entries');
    var count = 0;
    for (final item in list) {
      final incoming = AddressBookEntry.fromJson(item);
      if (incoming == null) continue;
      count++;
      final existing = _entries[incoming.id];
      if (existing == null) {
        _entries[incoming.id] = incoming;
        continue;
      }
      existing.key ??= incoming.key;
      if (incoming.alias.isNotEmpty) existing.alias = incoming.alias;
      if (incoming.notes.isNotEmpty) existing.notes = incoming.notes;
      existing.favorite = existing.favorite || incoming.favorite;
      existing.tags = {...existing.tags, ...incoming.tags}.toList();
      _mergeAddresses(existing, incoming.addresses);
      existing.gateways = {...incoming.gateways, ...existing.gateways}.take(_maxAddresses).toList();
    }
    await _save();
    return count;
  }

  void _mergeAddresses(AddressBookEntry e, List<String> fresh) {
    final merged = <String>[];
    for (final a in [...fresh, ...e.addresses]) {
      if (a.isNotEmpty && !merged.contains(a)) merged.add(a);
    }
    e.addresses = merged.take(_maxAddresses).toList();
  }

  void _load() {
    final raw = _prefs.getString(_key);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        for (final item in list) {
          final e = AddressBookEntry.fromJson(item);
          if (e != null) _entries[e.id] = e;
        }
      }
    } on FormatException {
      // A corrupt book is treated as empty rather than blocking startup.
    }
  }

  Future<void> _save() async {
    await _prefs.setString(_key, jsonEncode(_entries.values.map((e) => e.toJson()).toList()));
    notifyListeners();
  }
}
