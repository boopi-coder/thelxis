import 'package:flutter_webrtc/flutter_webrtc.dart';

num _num(Object? v) => v is num ? v : (v is String ? num.tryParse(v) ?? 0 : 0);

/// Inbound video as libwebrtc reports it.
class VideoProbe {
  const VideoProbe(this.framesDecoded, this.width, this.height, this.bytes);

  final num framesDecoded;
  final num width;
  final num height;
  final num bytes;

  bool get decoding => framesDecoded > 0 && width > 0 && height > 0;

  @override
  String toString() => 'framesDecoded=$framesDecoded ${width}x$height bytesReceived=$bytes';
}

Future<VideoProbe> probeInboundVideo(RTCPeerConnection pc) async {
  for (final r in await pc.getStats()) {
    if (r.type != 'inbound-rtp') continue;
    final kind = r.values['kind'] ?? r.values['mediaType'];
    if (kind != 'video') continue;
    return VideoProbe(
      _num(r.values['framesDecoded']),
      _num(r.values['frameWidth']),
      _num(r.values['frameHeight']),
      _num(r.values['bytesReceived']),
    );
  }
  return const VideoProbe(0, 0, 0, 0);
}

/// The ICE pair the connection ended up using.
class SelectedPair {
  const SelectedPair({required this.localType, required this.remoteType, required this.raw});

  /// `host`, `srflx`, `prflx` or `relay`.
  final String? localType;
  final String? remoteType;
  final Map<dynamic, dynamic> raw;

  @override
  String toString() => 'local=$localType remote=$remoteType';
}

Future<SelectedPair?> probeSelectedPair(RTCPeerConnection pc) async {
  final reports = await pc.getStats();
  final byId = {for (final r in reports) r.id: r};

  StatsReport? pair;
  for (final r in reports) {
    if (r.type == 'transport') {
      final id = r.values['selectedCandidatePairId'];
      if (id is String && byId[id] != null) pair = byId[id];
    }
  }
  pair ??= reports.cast<StatsReport?>().firstWhere(
        (r) =>
            r!.type == 'candidate-pair' &&
            (r.values['nominated'] == true || r.values['selected'] == true) &&
            r.values['state'] == 'succeeded',
        orElse: () => null,
      );
  if (pair == null) return null;

  String? typeOf(Object? id) {
    final c = id is String ? byId[id] : null;
    final t = c?.values['candidateType'] ?? c?.values['type'];
    return t is String ? t : null;
  }

  return SelectedPair(
    localType: typeOf(pair.values['localCandidateId']),
    remoteType: typeOf(pair.values['remoteCandidateId']),
    raw: pair.values,
  );
}
