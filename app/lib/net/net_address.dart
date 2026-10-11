import 'dart:io';

import 'connectivity/connectivity.dart';

/// A network location of a listener's signaling port (PROTOCOL.md section 3).
class NetAddress {
  const NetAddress(this.host, this.port);

  /// IPv4/IPv6 literal (without brackets) or DNS name.
  final String host;
  final int port;

  bool get isIPv6 => host.contains(':');

  /// Canonical `host:port` / `[v6]:port` form used on the wire and in the UI.
  String get hostPort => isIPv6 ? '[$host]:$port' : '$host:$port';

  /// `host` as it must appear in a URL host position (v6 bracketed).
  String get urlHost => isIPv6 ? '[$host]' : host;

  Uri get signalingUri =>
      Uri(scheme: 'ws', host: host, port: port, path: '/thelxis');

  /// Parses `host`, `host:port`, `[v6]`, `[v6]:port` or a bare IPv6 literal.
  /// Returns null for anything that is not a plausible address.
  static NetAddress? parse(String input, {int defaultPort = ThelxisPorts.signalingTcp}) {
    var s = input.trim();
    if (s.isEmpty || s.contains(RegExp(r'[\s/@?#,]'))) return null;
    String host;
    int port = defaultPort;

    if (s.startsWith('[')) {
      final end = s.indexOf(']');
      if (end < 0) return null;
      host = s.substring(1, end);
      final rest = s.substring(end + 1);
      if (rest.isNotEmpty) {
        if (!rest.startsWith(':')) return null;
        final p = _port(rest.substring(1));
        if (p == null) return null;
        port = p;
      }
      return _isIPv6(host) ? NetAddress(host.toLowerCase(), port) : null;
    }

    final colons = ':'.allMatches(s).length;
    if (colons > 1) {
      // Bare IPv6 literal without brackets cannot carry a port.
      return _isIPv6(s) ? NetAddress(s.toLowerCase(), defaultPort) : null;
    }
    if (colons == 1) {
      final i = s.indexOf(':');
      final p = _port(s.substring(i + 1));
      if (p == null) return null;
      port = p;
      s = s.substring(0, i);
    }
    host = s;
    if (_looksLikeIPv4(host)) return _isIPv4(host) ? NetAddress(host, port) : null;
    return _isHostname(host) ? NetAddress(host.toLowerCase(), port) : null;
  }

  static int? _port(String s) {
    if (!RegExp(r'^\d{1,5}$').hasMatch(s)) return null;
    final p = int.parse(s);
    return p >= 1 && p <= 65535 ? p : null;
  }

  static bool _looksLikeIPv4(String s) => RegExp(r'^[\d.]+$').hasMatch(s);

  static bool _isIPv4(String s) {
    final parts = s.split('.');
    if (parts.length != 4) return false;
    for (final p in parts) {
      if (p.isEmpty || p.length > 3) return false;
      final n = int.tryParse(p);
      if (n == null || n > 255) return false;
    }
    return true;
  }

  static bool _isIPv6(String s) {
    final a = InternetAddress.tryParse(s);
    return a != null && a.type == InternetAddressType.IPv6;
  }

  static final RegExp _hostRe = RegExp(
    r'^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$',
  );

  static bool _isHostname(String s) => s.length <= 253 && _hostRe.hasMatch(s);

  @override
  bool operator ==(Object other) =>
      other is NetAddress && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => hostPort;
}

/// Parses a list of address strings, dropping invalid ones and duplicates.
List<NetAddress> parseAddressList(Iterable<String> raw) {
  final seen = <NetAddress>{};
  final out = <NetAddress>[];
  for (final r in raw) {
    final a = NetAddress.parse(r);
    if (a != null && seen.add(a)) out.add(a);
  }
  return out;
}
