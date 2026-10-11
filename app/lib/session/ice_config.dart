import '../net/net_address.dart';
import '../net/signaling_channel.dart';
import '../protocol/signaling_messages.dart';

const String kPublicStunUrl = 'stun:stun.l.google.com:19302';

/// Builds the `RTCPeerConnection` configuration per PROTOCOL.md section 4.3.
///
/// * The dialer uses the listener's embedded STUN/TURN, addressed through the
///   host it actually connected to ([turnHost]).
/// * The listener uses no ICE servers.
/// * A public STUN server is added only when the user opted in.
Map<String, dynamic> buildRtcConfiguration({
  required SignalingRole role,
  TurnInfo? turn,
  NetAddress? turnHost,
  bool publicStun = false,
}) {
  final servers = <Map<String, dynamic>>[];
  if (role == SignalingRole.dialer && turn != null && turnHost != null) {
    final h = turnHost.urlHost;
    servers.add({
      'urls': ['stun:$h:${turn.udpPort}'],
    });
    servers.add({
      'urls': [
        'turn:$h:${turn.udpPort}?transport=udp',
        'turn:$h:${turn.tcpPort}?transport=tcp',
      ],
      'username': turn.username,
      'credential': turn.credential,
    });
  }
  if (publicStun) {
    servers.add({
      'urls': [kPublicStunUrl],
    });
  }
  return {
    'iceServers': servers,
    'bundlePolicy': 'max-bundle',
    'sdpSemantics': 'unified-plan',
    'iceTransportPolicy': 'all',
  };
}
