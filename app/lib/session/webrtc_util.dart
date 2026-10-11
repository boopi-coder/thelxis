import 'dart:async';
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

/// Resolves when ICE gathering of [pc] is complete, or after [timeout].
/// Create it before `setLocalDescription` (which starts gathering) so the
/// state change cannot be missed.
class IceGatheringWatch {
  IceGatheringWatch(this._pc) {
    _previous = _pc.onIceGatheringState;
    _pc.onIceGatheringState = (state) {
      _previous?.call(state);
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) _check();
    };
  }

  final RTCPeerConnection _pc;
  void Function(RTCIceGatheringState state)? _previous;
  final Completer<void> _done = Completer<void>();

  void _check() {
    if (!_done.isCompleted) _done.complete();
  }

  /// Waits for completion (at most [timeout]) and restores the previous
  /// handler. Gathering that is still running at the timeout is simply cut
  /// off: the candidates found so far are in the description.
  Future<void> complete({Duration timeout = const Duration(seconds: 5)}) async {
    if (_pc.iceGatheringState == RTCIceGatheringState.RTCIceGatheringStateComplete) _check();
    try {
      await _done.future.timeout(timeout);
    } on TimeoutException {
      // Use what we have.
    } finally {
      _pc.onIceGatheringState = _previous;
    }
  }
}

/// The parts of the controlled side's PeerConnection (PROTOCOL.md section 5):
/// the screen transceiver and the three data channels. Shared by normal
/// sessions and by connection-code offers, which are built before any viewer
/// is known.
class HostPeerParts {
  HostPeerParts({
    required this.pc,
    required this.sender,
    required this.control,
    required this.input,
    required this.files,
  });

  final RTCPeerConnection pc;
  final RTCRtpSender sender;
  final RTCDataChannel control;
  final RTCDataChannel input;
  final RTCDataChannel files;
}

Future<HostPeerParts> createHostPeerConnection(Map<String, dynamic> config) async {
  final pc = await createPeerConnection(config);
  MediaStream? tag;
  try {
    // A stream id in the SDP lets the viewer attach the track to a stream.
    tag = await createLocalMediaStream('thelxis-screen');
  } on Object {
    // Not essential: the viewer wraps a stream-less track itself.
  }
  final tx = await pc.addTransceiver(
    kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
    init: RTCRtpTransceiverInit(
      direction: TransceiverDirection.SendOnly,
      streams: tag == null ? null : [tag],
    ),
  );
  final control = await pc.createDataChannel('control', RTCDataChannelInit()..ordered = true);
  final input = await pc.createDataChannel('input', RTCDataChannelInit()..ordered = true);
  final files = await pc.createDataChannel('files', RTCDataChannelInit()..ordered = true);
  return HostPeerParts(pc: pc, sender: tx.sender, control: control, input: input, files: files);
}
