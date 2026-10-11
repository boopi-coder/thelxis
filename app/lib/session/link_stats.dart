/// Connection statistics derived from WebRTC `getStats()` reports. The parser
/// is pure Dart over plain maps so it can be unit tested without the plugin.
library;

import '../l10n/strings.dart';

/// One entry of a stats report (id, type and member values).
class StatEntry {
  const StatEntry(this.id, this.type, this.values);
  final String id;
  final String type;
  final Map<dynamic, dynamic> values;
}

/// How media currently flows (shown in the stats overlay).
enum LinkPath { unknown, lan, ipv6, direct, relay }

class LinkStats {
  const LinkStats({
    this.rttMs,
    this.fps,
    this.bitrateBps,
    this.lossPercent,
    this.width,
    this.height,
    this.codec,
    this.path = LinkPath.unknown,
  });

  static const LinkStats empty = LinkStats();

  final double? rttMs;
  final double? fps;
  final double? bitrateBps;
  final double? lossPercent;
  final int? width;
  final int? height;
  final String? codec;
  final LinkPath path;

  String get pathLabel => switch (path) {
        LinkPath.lan => S.current.t('path.lan'),
        LinkPath.ipv6 => 'IPv6',
        LinkPath.direct => S.current.t('path.direct'),
        LinkPath.relay => S.current.t('path.relay'),
        LinkPath.unknown => '—',
      };
}

double? _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// Keeps the previous sample so rates (bitrate, fps, loss) can be computed
/// from counter deltas.
class StatsSampler {
  double? _lastTimeMs;
  double? _lastBytes;
  double? _lastFrames;
  double? _lastLost;
  double? _lastPackets;

  void reset() {
    _lastTimeMs = null;
    _lastBytes = null;
    _lastFrames = null;
    _lastLost = null;
    _lastPackets = null;
  }

  /// [nowMs] is a monotonic clock in milliseconds.
  LinkStats update(List<StatEntry> reports, {required double nowMs}) {
    final byId = {for (final r in reports) r.id: r};

    StatEntry? media;
    var outbound = false;
    for (final r in reports) {
      if (r.type == 'inbound-rtp' && _isVideo(r)) {
        media = r;
        break;
      }
    }
    if (media == null) {
      for (final r in reports) {
        if (r.type == 'outbound-rtp' && _isVideo(r)) {
          media = r;
          outbound = true;
          break;
        }
      }
    }

    final pair = _selectedPair(reports, byId);
    var rtt = pair == null ? null : _num(pair.values['currentRoundTripTime']);
    if (rtt == null) {
      for (final r in reports) {
        if (r.type == 'remote-inbound-rtp') {
          rtt = _num(r.values['roundTripTime']);
          if (rtt != null) break;
        }
      }
    }

    double? bitrate;
    double? fps;
    double? loss;
    int? width;
    int? height;
    String? codec;

    if (media != null) {
      final v = media.values;
      final bytes = _num(v[outbound ? 'bytesSent' : 'bytesReceived']);
      final frames = _num(v[outbound ? 'framesEncoded' : 'framesDecoded']);
      final lost = outbound ? null : _num(v['packetsLost']);
      final packets = outbound ? null : _num(v['packetsReceived']);
      final dt = _lastTimeMs == null ? null : (nowMs - _lastTimeMs!) / 1000.0;

      if (dt != null && dt > 0) {
        if (bytes != null && _lastBytes != null) {
          bitrate = ((bytes - _lastBytes!) * 8 / dt).clamp(0, double.infinity).toDouble();
        }
        if (frames != null && _lastFrames != null) {
          fps = ((frames - _lastFrames!) / dt).clamp(0, double.infinity).toDouble();
        }
        if (lost != null && packets != null && _lastLost != null && _lastPackets != null) {
          final dLost = (lost - _lastLost!).clamp(0, double.infinity);
          final dPackets = (packets - _lastPackets!).clamp(0, double.infinity);
          final total = dLost + dPackets;
          loss = total > 0 ? dLost / total * 100 : 0;
        }
      }
      fps ??= _num(v['framesPerSecond']);
      if (loss == null && lost != null && packets != null && _lastLost == null) {
        final total = lost + packets;
        loss = total > 0 ? lost.clamp(0, double.infinity) / total * 100 : 0;
      }

      _lastBytes = bytes;
      _lastFrames = frames;
      _lastLost = lost;
      _lastPackets = packets;

      width = _num(v['frameWidth'])?.toInt();
      height = _num(v['frameHeight'])?.toInt();
      final codecId = v['codecId'];
      final codecReport = codecId is String ? byId[codecId] : null;
      final mime = codecReport?.values['mimeType'];
      if (mime is String) codec = mime.contains('/') ? mime.split('/').last : mime;
    }
    _lastTimeMs = nowMs;

    return LinkStats(
      rttMs: rtt == null ? null : rtt * 1000,
      fps: fps,
      bitrateBps: bitrate,
      lossPercent: loss,
      width: width,
      height: height,
      codec: codec,
      path: _path(pair, byId),
    );
  }

  static bool _isVideo(StatEntry r) {
    final kind = r.values['kind'] ?? r.values['mediaType'];
    return kind == 'video';
  }

  static bool _truthy(Object? v) => v == true || v == 'true' || v == 1;

  static StatEntry? _selectedPair(List<StatEntry> reports, Map<String, StatEntry> byId) {
    for (final r in reports) {
      if (r.type == 'transport') {
        final id = r.values['selectedCandidatePairId'];
        if (id is String && byId[id] != null) return byId[id];
      }
    }
    StatEntry? best;
    for (final r in reports) {
      if (r.type != 'candidate-pair') continue;
      final selected = _truthy(r.values['selected']) || _truthy(r.values['nominated']);
      final succeeded = r.values['state'] == 'succeeded';
      if (selected && succeeded) return r;
      if (succeeded) {
        final bytes = (_num(r.values['bytesReceived']) ?? 0) + (_num(r.values['bytesSent']) ?? 0);
        final bestBytes = best == null
            ? -1
            : (_num(best.values['bytesReceived']) ?? 0) + (_num(best.values['bytesSent']) ?? 0);
        if (bytes > bestBytes) best = r;
      }
    }
    return best;
  }

  static LinkPath _path(StatEntry? pair, Map<String, StatEntry> byId) {
    if (pair == null) return LinkPath.unknown;
    StatEntry? cand(Object? id) => id is String ? byId[id] : null;
    final local = cand(pair.values['localCandidateId']);
    final remote = cand(pair.values['remoteCandidateId']);
    if (local == null && remote == null) return LinkPath.unknown;
    String? type(StatEntry? c) {
      final t = c?.values['candidateType'] ?? c?.values['type'];
      return t is String ? t : null;
    }

    String? address(StatEntry? c) {
      final a = c?.values['address'] ?? c?.values['ip'] ?? c?.values['ipAddress'];
      return a is String ? a : null;
    }

    if (type(local) == 'relay' || type(remote) == 'relay') return LinkPath.relay;
    final la = address(local);
    final ra = address(remote);
    if (la != null && ra != null && isPrivateAddress(la) && isPrivateAddress(ra)) {
      return LinkPath.lan;
    }
    if ((la != null && la.contains(':')) || (ra != null && ra.contains(':'))) {
      return LinkPath.ipv6;
    }
    return LinkPath.direct;
  }
}

/// RFC1918, link-local, loopback and IPv6 unique-local/link-local addresses.
bool isPrivateAddress(String address) {
  final a = address.toLowerCase();
  if (a.contains(':')) {
    return a == '::1' || a.startsWith('fe80') || a.startsWith('fc') || a.startsWith('fd');
  }
  final p = a.split('.').map(int.tryParse).toList();
  if (p.length != 4 || p.any((e) => e == null)) return false;
  final o1 = p[0]!, o2 = p[1]!;
  return o1 == 10 ||
      o1 == 127 ||
      (o1 == 172 && o2 >= 16 && o2 <= 31) ||
      (o1 == 192 && o2 == 168) ||
      (o1 == 169 && o2 == 254);
}
