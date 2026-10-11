import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/base64url.dart';
import '../core/identity.dart';
import '../core/log.dart';
import '../core/thelxis_id.dart';
import 'connectivity/connectivity.dart';
import 'peer_identity.dart';

const _log = Logger('discovery');

/// A device that answered a LAN broadcast (PROTOCOL.md section 7). The reply
/// is unauthenticated; the signed handshake verifies the ID before any use.
class DiscoveredPeer {
  const DiscoveredPeer({
    required this.id,
    required this.key,
    required this.name,
    required this.os,
    required this.host,
    required this.port,
    required this.lastSeen,
  });

  final String id;
  final String key;
  final String name;
  final String os;
  final String host;
  final int port;
  final DateTime lastSeen;

  String get address => '$host:$port';
  String get formattedId => formatThelxisId(id);

  DiscoveredPeer withLastSeen(DateTime t) => DiscoveredPeer(
        id: id,
        key: key,
        name: name,
        os: os,
        host: host,
        port: port,
        lastSeen: t,
      );
}

/// `{"t":"discover","v":2}`
String buildDiscover() => jsonEncode({'t': 'discover', 'v': 2});

/// Reply sent by hosts: `{"t":"here",...}`.
String buildHere({
  required Identity identity,
  required LocalPeerInfo info,
  required int port,
}) =>
    jsonEncode({
      't': 'here',
      'v': 2,
      'id': identity.id,
      'key': identity.publicKeyB64,
      'name': info.name,
      'os': info.os,
      'port': port,
    });

bool isDiscover(String text) {
  try {
    final j = jsonDecode(text);
    return j is Map && j['t'] == 'discover';
  } on FormatException {
    return false;
  }
}

/// Parses a `here` reply from [sourceHost]; returns null if malformed or if
/// the advertised ID does not match the advertised key (spoofed label).
DiscoveredPeer? parseHere(String text, String sourceHost, {DateTime? now}) {
  final Object? j;
  try {
    j = jsonDecode(text);
  } on FormatException {
    return null;
  }
  if (j is! Map || j['t'] != 'here') return null;
  final key = j['key'];
  final port = j['port'];
  if (key is! String || port is! int || port < 1 || port > 65535) return null;
  final raw = tryB64uDecode(key);
  if (raw == null || raw.length != 32) return null;
  final id = thelxisIdFromPublicKey(raw);
  final claimed = parseThelxisId(j['id'] as String?);
  if (claimed != id) return null;
  String clip(Object? v, int max, String fallback) {
    if (v is! String || v.isEmpty) return fallback;
    return v.length <= max ? v : v.substring(0, max);
  }

  return DiscoveredPeer(
    id: id,
    key: key,
    name: clip(j['name'], 64, 'Unknown'),
    os: clip(j['os'], 16, 'unknown'),
    host: sourceHost,
    port: port,
    lastSeen: now ?? DateTime.now(),
  );
}

/// LAN discovery: a responder (hosts answer broadcasts) and a browser
/// (viewers broadcast while the Devices screen is visible).
class LanDiscovery extends ChangeNotifier {
  LanDiscovery({
    required this.identity,
    required this.localInfo,
    required this.signalingPort,
    this.discoveryPort = ThelxisPorts.discoveryUdp,
    this.scanInterval = const Duration(seconds: 5),
    this.expiry = const Duration(seconds: 15),
  });

  final Identity identity;
  final LocalPeerInfo Function() localInfo;
  final int Function() signalingPort;
  final int discoveryPort;
  final Duration scanInterval;
  final Duration expiry;

  RawDatagramSocket? _responder;
  RawDatagramSocket? _browser;
  Timer? _scanTimer;
  Timer? _pruneTimer;
  int _viewers = 0;
  int _repliesThisSecond = 0;
  DateTime _replyWindow = DateTime.now();
  final Map<String, DiscoveredPeer> _peers = {};

  List<DiscoveredPeer> get peers {
    final list = _peers.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  bool get isResponding => _responder != null;

  /// Starts answering broadcasts. Failure (port in use, no permission) is
  /// logged and tolerated: the device simply is not discoverable.
  Future<bool> startResponder() async {
    if (_responder != null) return true;
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
      _responder = socket;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = socket.receive();
        if (d == null) return;
        _onDiscover(socket, d);
      });
      return true;
    } on Object catch (e) {
      _log.w('discovery responder unavailable', e);
      return false;
    }
  }

  Future<void> stopResponder() async {
    _responder?.close();
    _responder = null;
  }

  void _onDiscover(RawDatagramSocket socket, Datagram d) {
    if (d.data.length > 512) return;
    final String text;
    try {
      text = utf8.decode(d.data);
    } on FormatException {
      return;
    }
    if (!isDiscover(text)) return;
    final now = DateTime.now();
    if (now.difference(_replyWindow) > const Duration(seconds: 1)) {
      _replyWindow = now;
      _repliesThisSecond = 0;
    }
    if (++_repliesThisSecond > 20) return;
    final reply = buildHere(identity: identity, info: localInfo(), port: signalingPort());
    socket.send(utf8.encode(reply), d.address, d.port);
  }

  /// Called by the Devices screen while it is visible. Each call must be
  /// balanced by [releaseBrowsing].
  void acquireBrowsing() {
    _viewers++;
    if (_viewers == 1) {
      _scanTimer = Timer.periodic(scanInterval, (_) => scanNow());
      _pruneTimer = Timer.periodic(const Duration(seconds: 3), (_) => _prune());
      unawaited(scanNow());
    }
  }

  void releaseBrowsing() {
    if (_viewers == 0) return;
    _viewers--;
    if (_viewers == 0) {
      _scanTimer?.cancel();
      _pruneTimer?.cancel();
      _scanTimer = _pruneTimer = null;
      _browser?.close();
      _browser = null;
    }
  }

  /// Broadcasts one discover packet to every interface.
  Future<void> scanNow() async {
    try {
      var socket = _browser;
      if (socket == null) {
        socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        socket.broadcastEnabled = true;
        socket.listen((event) {
          if (event != RawSocketEvent.read) return;
          final d = socket!.receive();
          if (d != null) _onReply(d);
        });
        _browser = socket;
      }
      final payload = utf8.encode(buildDiscover());
      for (final target in await _broadcastTargets()) {
        try {
          socket.send(payload, target, discoveryPort);
        } on Object catch (e) {
          _log.d('broadcast to ${target.address} failed: $e');
        }
      }
    } on Object catch (e) {
      _log.w('discovery scan failed', e);
    }
  }

  void _onReply(Datagram d) {
    if (d.data.length > 1024) return;
    final String text;
    try {
      text = utf8.decode(d.data);
    } on FormatException {
      return;
    }
    final peer = parseHere(text, d.address.address);
    if (peer == null || peer.id == identity.id) return;
    final known = _peers[peer.id];
    _peers[peer.id] = peer;
    if (known == null ||
        known.name != peer.name ||
        known.host != peer.host ||
        known.port != peer.port) {
      notifyListeners();
    }
  }

  void _prune() {
    final cutoff = DateTime.now().subtract(expiry);
    final before = _peers.length;
    _peers.removeWhere((_, p) => p.lastSeen.isBefore(cutoff));
    if (_peers.length != before) notifyListeners();
  }

  /// Limited broadcast plus an assumed /24 broadcast per IPv4 interface address
  /// (Dart does not expose netmasks).
  static Future<List<InternetAddress>> _broadcastTargets() async {
    final targets = <String>{'255.255.255.255'};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final i in interfaces) {
        for (final a in i.addresses) {
          final parts = a.address.split('.');
          if (parts.length == 4) targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
        }
      }
    } on Object catch (e) {
      _log.d('interface list failed: $e');
    }
    return targets.map(InternetAddress.new).toList();
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    _pruneTimer?.cancel();
    _responder?.close();
    _browser?.close();
    super.dispose();
  }
}
