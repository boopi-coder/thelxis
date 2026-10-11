import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/sdp_fingerprint.dart';
import 'link_stats.dart';

/// Offer constraints for the host: the transceivers are explicit, so no
/// implicit receive m-lines are wanted.
const Map<String, dynamic> kHostOfferConstraints = {
  'mandatory': {'OfferToReceiveAudio': false, 'OfferToReceiveVideo': false},
  'optional': <dynamic>[],
};

/// Same, but forcing fresh ICE credentials (PROTOCOL.md section 5: restart).
const Map<String, dynamic> kIceRestartConstraints = {
  'mandatory': {
    'OfferToReceiveAudio': false,
    'OfferToReceiveVideo': false,
    'IceRestart': true,
  },
  'optional': <dynamic>[],
};

const Map<String, dynamic> kAnswerConstraints = {
  'mandatory': <String, dynamic>{},
  'optional': <dynamic>[],
};

/// The DTLS fingerprints of this session's local and remote descriptions, as
/// fed into the password proof.
Future<({String? local, String? remote})> readFingerprints(RTCPeerConnection pc) async {
  final local = await pc.getLocalDescription();
  final remote = await pc.getRemoteDescription();
  return (
    local: extractDtlsFingerprint(local?.sdp),
    remote: extractDtlsFingerprint(remote?.sdp),
  );
}

Future<List<StatEntry>> readStats(RTCPeerConnection pc) async {
  final reports = await pc.getStats();
  return [
    for (final r in reports)
      StatEntry(r.id, r.type, Map<dynamic, dynamic>.from(r.values)),
  ];
}

/// Decodes a text data-channel message to JSON, or null if it is binary or
/// malformed.
Object? decodeJsonMessage(RTCDataChannelMessage message) {
  if (message.isBinary) return null;
  try {
    return jsonDecode(message.text);
  } on FormatException {
    return null;
  }
}

Future<void> sendJson(RTCDataChannel? channel, Map<String, dynamic> json) async {
  if (channel == null || channel.state != RTCDataChannelState.RTCDataChannelOpen) return;
  await channel.send(RTCDataChannelMessage(jsonEncode(json)));
}

RTCDegradationPreference degradationFor(String wire) {
  switch (wire) {
    case 'maintain-framerate':
      return RTCDegradationPreference.MAINTAIN_FRAMERATE;
    case 'maintain-resolution':
      return RTCDegradationPreference.MAINTAIN_RESOLUTION;
    default:
      return RTCDegradationPreference.BALANCED;
  }
}
