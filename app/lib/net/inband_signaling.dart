import 'dart:async';
import 'dart:collection';

import '../core/identity.dart';
import '../core/log.dart';
import '../l10n/strings.dart';
import 'handshake.dart';
import 'signaling_channel.dart';

const _log = Logger('inband');

/// Signaling for sessions created from connection codes (PROTOCOL.md section
/// 12). There is no WebSocket: after the first offer/answer (which travelled in
/// the codes) the later ones, ICE restarts and candidates, ride the `control`
/// data channel as `{"t":"rtc","data":{...}}`.
///
/// SDPs are signed like on the WebSocket (section 4.2), with the host's nonce
/// `nH` and the viewer's nonce `nV` from the codes in the places of the
/// dialer and listener nonces.
class InBandSignaling implements SessionSignaling {
  InBandSignaling({
    required this.identity,
    required this.role,
    required this.peerKey,
    required this.hostNonce,
    required this.viewerNonce,
  });

  final Identity identity;

  /// Host = [SignalingRole.listener] (it made the offer), viewer =
  /// [SignalingRole.dialer].
  @override
  final SignalingRole role;
  final String peerKey;
  final String hostNonce;
  final String viewerNonce;

  void Function(Map<String, dynamic> message)? _transport;
  final Queue<Map<String, dynamic>> _outbox = Queue();
  final _events = StreamController<SignalEvent>();
  final _closed = Completer<void>();
  bool _ended = false;

  @override
  Stream<SignalEvent> get events => _events.stream;

  @override
  Future<void> get closed => _closed.future;

  @override
  bool get isClosed => _ended;

  @override
  bool get isAttached => _transport != null;

  @override
  void debugDropSocket() => _transport = null;

  /// Starts carrying messages over [send] (the open `control` channel) and
  /// flushes what was queued. Pass null when the channel goes away.
  void attachTransport(void Function(Map<String, dynamic> message)? send) {
    _transport = send;
    if (send == null) return;
    while (_outbox.isNotEmpty) {
      send(_outbox.removeFirst());
    }
  }

  @override
  Future<void> sendOffer(String sdp) => _sendSdp('offer', sdp);

  @override
  Future<void> sendAnswer(String sdp) => _sendSdp('answer', sdp);

  @override
  void sendCandidate({required String candidate, String? sdpMid, int? sdpMLineIndex}) {
    // Until the control channel exists, the codes' SDPs (ICE gathering was
    // complete) already carry every candidate.
    if (_ended || _transport == null) return;
    _send({'type': 'candidate', 'candidate': candidate, 'sdpMid': sdpMid, 'sdpMLineIndex': sdpMLineIndex});
  }

  @override
  void bye(String reason) {
    // The `bye` control message of the session says it; nothing more to send.
    _finish();
  }

  @override
  void dispose() => _finish();

  Future<void> _sendSdp(String type, String sdp) async {
    final sig = await signPayload(
      identity,
      sdpPayload(dialerNonce: hostNonce, listenerNonce: viewerNonce, type: type, sdp: sdp),
    );
    _send({'type': type, 'sdp': sdp, 'sig': sig});
  }

  void _send(Map<String, dynamic> data) {
    if (_ended) return;
    final t = _transport;
    if (t != null) {
      t(data);
      return;
    }
    if (_outbox.length >= 16) _outbox.removeFirst();
    _outbox.add(data);
  }

  /// The `data` of an `rtc` message from the peer. The host only takes
  /// answers (it is the one that offers), the viewer only offers; both take
  /// candidates. Anything else is dropped.
  Future<void> onRtc(Map<String, dynamic> data) async {
    if (_ended) return;
    final type = data['type'];
    if (type == 'candidate') {
      final c = data['candidate'];
      if (c is! String || c.length > 2048) return;
      final mid = data['sdpMid'];
      final idx = data['sdpMLineIndex'];
      _events.add(RemoteCandidate(c, mid is String ? mid : null, idx is int ? idx : null));
      return;
    }
    final expected = role == SignalingRole.listener ? 'answer' : 'offer';
    if (type != expected) {
      _log.d('ignoring rtc $type');
      return;
    }
    final sdp = data['sdp'];
    final sig = data['sig'];
    final ok = sdp is String &&
        sdp.length <= 256 * 1024 &&
        sig is String &&
        await verifyPayload(
          peerKey: peerKey,
          signature: sig,
          payload: sdpPayload(
            dialerNonce: hostNonce,
            listenerNonce: viewerNonce,
            type: type,
            sdp: sdp,
          ),
        );
    if (_ended) return;
    if (!ok) {
      _log.w('in-band SDP signature verification failed');
      _events.add(SignatureFailure(S.current.t('warn.sig.body')));
      _finish();
      return;
    }
    _events.add(RemoteSdp(type, sdp));
  }

  void _finish() {
    if (_ended) return;
    _ended = true;
    _outbox.clear();
    _transport = null;
    unawaited(_events.close());
    if (!_closed.isCompleted) _closed.complete();
  }
}
