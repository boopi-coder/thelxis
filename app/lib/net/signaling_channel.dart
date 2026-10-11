import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../core/identity.dart';
import '../core/log.dart';
import '../l10n/strings.dart';
import '../protocol/signaling_messages.dart';
import 'handshake.dart';
import 'ws_peer.dart';

const _log = Logger('signaling');

enum SignalingRole { dialer, listener }

/// Events surfaced to the session that owns a [SignalingChannel].
sealed class SignalEvent {
  const SignalEvent();
}

/// A remote offer or answer whose Ed25519 signature has been verified.
class RemoteSdp extends SignalEvent {
  const RemoteSdp(this.type, this.sdp);
  final String type;
  final String sdp;
}

class RemoteCandidate extends SignalEvent {
  const RemoteCandidate(this.candidate, this.sdpMid, this.sdpMLineIndex);
  final String candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;
}

/// The peer ended the session.
class RemoteBye extends SignalEvent {
  const RemoteBye(this.reason);
  final String reason;
}

/// An SDP failed signature verification: possible interception. The channel
/// has already sent `bye(error)` and closed itself.
class SignatureFailure extends SignalEvent {
  const SignatureFailure(this.message);
  final String message;
}

/// The WebSocket dropped; media is unaffected. [SignalingResumed] follows.
class SignalingDetached extends SignalEvent {
  const SignalingDetached();
}

class SignalingResumed extends SignalEvent {
  const SignalingResumed();
}

/// A freshly re-established signaling connection for an existing session.
class ResumedConnection {
  const ResumedConnection(this.peer, this.dialerNonce, this.listenerNonce);
  final WsPeer peer;
  final String dialerNonce;
  final String listenerNonce;
}

typedef ResumeCallback = Future<ResumedConnection?> Function(String sid);

/// Signaling for exactly one session over one (replaceable) WebSocket.
///
/// Offers and answers are signed with the device key over a transcript that
/// binds both handshake nonces, so a verified SDP proves its DTLS fingerprints
/// come from the authenticated peer (PROTOCOL.md section 4.2).
class SignalingChannel {
  SignalingChannel({
    required this.sid,
    required this.identity,
    required this.role,
    required this.peerKey,
    required WsPeer peer,
    required String initialDialerNonce,
    required String initialListenerNonce,
    this.resume,
    this.pingInterval = const Duration(seconds: 20),
    this.silenceTimeout = const Duration(seconds: 60),
  })  : _dialerNonce = initialDialerNonce,
        _listenerNonce = initialListenerNonce {
    _bind(peer);
    _keepalive = Timer.periodic(pingInterval, (_) => _tick());
  }

  final String sid;
  final Identity identity;
  final SignalingRole role;

  /// The peer's base64url public key (already authenticated by the handshake).
  final String peerKey;

  /// Dialer only: re-runs the handshake with `resume` after a drop.
  final ResumeCallback? resume;

  final Duration pingInterval;
  final Duration silenceTimeout;

  String _dialerNonce;
  String _listenerNonce;
  WsPeer? _peer;
  bool _ended = false;
  bool _resuming = false;
  Timer? _keepalive;
  final Queue<SignalingMessage> _outbox = Queue();
  final _events = StreamController<SignalEvent>();
  final _closed = Completer<void>();

  /// Verified inbound events. Single-subscription: events raised before the
  /// session listens are buffered, so a fast offer is never lost.
  Stream<SignalEvent> get events => _events.stream;

  /// Completes when the channel is finished (bye either way, or [dispose]).
  Future<void> get closed => _closed.future;

  bool get isClosed => _ended;

  /// Whether a WebSocket is currently attached.
  bool get isAttached => _peer != null && !_peer!.isClosed;

  Future<void> sendOffer(String sdp) => _sendSdp('offer', sdp);

  Future<void> sendAnswer(String sdp) => _sendSdp('answer', sdp);

  void sendCandidate({required String candidate, String? sdpMid, int? sdpMLineIndex}) {
    _send(SigSignal({
      'type': 'candidate',
      'candidate': candidate,
      'sdpMid': sdpMid,
      'sdpMLineIndex': sdpMLineIndex,
    }));
  }

  /// Tells the peer the session is over and closes.
  void bye(String reason) {
    if (_ended) return;
    final p = _peer;
    if (p != null && !p.isClosed) p.send(SigBye(reason));
    _finish();
  }

  /// Closes without notifying the peer (it already knows, or the session
  /// never started).
  void dispose() => _finish();

  /// Simulates a network drop of the WebSocket without ending the session.
  @visibleForTesting
  void debugDropSocket() => unawaited(_peer?.close());

  /// Listener side: a resumed WebSocket for this session (same peer key,
  /// fresh handshake nonces).
  void attach(WsPeer peer, {required String dialerNonce, required String listenerNonce}) {
    if (_ended) {
      unawaited(peer.close());
      return;
    }
    final old = _peer;
    _dialerNonce = dialerNonce;
    _listenerNonce = listenerNonce;
    _bind(peer);
    if (old != null) unawaited(old.close());
    _events.add(const SignalingResumed());
    _flush();
  }

  Future<void> _sendSdp(String type, String sdp) async {
    final payload = sdpPayload(
      dialerNonce: _dialerNonce,
      listenerNonce: _listenerNonce,
      type: type,
      sdp: sdp,
    );
    final sig = await signPayload(identity, payload);
    _send(SigSignal({'type': type, 'sdp': sdp, 'sig': sig}));
  }

  void _send(SignalingMessage m) {
    if (_ended) return;
    final p = _peer;
    if (p != null && !p.isClosed) {
      p.send(m);
      return;
    }
    if (_outbox.length >= 128) _outbox.removeFirst();
    _outbox.add(m);
  }

  void _flush() {
    final p = _peer;
    if (p == null || p.isClosed) return;
    while (_outbox.isNotEmpty) {
      p.send(_outbox.removeFirst());
    }
  }

  void _bind(WsPeer peer) {
    _peer = peer;
    peer.listen(
      onMessage: (m) => unawaited(_onMessage(peer, m)),
      onClose: () => _onPeerClosed(peer),
    );
  }

  Future<void> _onMessage(WsPeer from, SignalingMessage m) async {
    if (_ended || !identical(from, _peer)) return;
    switch (m) {
      case SigPing():
        from.send(const SigPong());
      case SigPong():
        break;
      case SigBye(:final reason):
        _events.add(RemoteBye(reason));
        _finish();
      case SigSignal(:final data):
        await _onSignal(data);
      case SigError(:final code):
        _log.w('peer error: $code');
      default:
        break;
    }
  }

  Future<void> _onSignal(Map<String, dynamic> data) async {
    final type = data['type'];
    if (type == 'candidate') {
      final c = data['candidate'];
      if (c is! String) return;
      final mid = data['sdpMid'];
      final idx = data['sdpMLineIndex'];
      _events.add(RemoteCandidate(c, mid is String ? mid : null, idx is int ? idx : null));
      return;
    }
    if (type != 'offer' && type != 'answer') return;
    final sdp = data['sdp'];
    final sig = data['sig'];
    final nD = _dialerNonce;
    final nL = _listenerNonce;
    final ok = sdp is String &&
        sig is String &&
        await verifyPayload(
          peerKey: peerKey,
          signature: sig,
          payload: sdpPayload(
            dialerNonce: nD,
            listenerNonce: nL,
            type: type,
            sdp: sdp,
          ),
        );
    if (_ended) return;
    if (!ok) {
      _log.w('SDP signature verification failed');
      _events.add(SignatureFailure(S.current.t('warn.sig.body')));
      bye('error');
      return;
    }
    _events.add(RemoteSdp(type, sdp));
  }

  void _onPeerClosed(WsPeer peer) {
    if (_ended || !identical(peer, _peer)) return;
    _peer = null;
    _events.add(const SignalingDetached());
    if (resume != null) unawaited(_resumeLoop());
  }

  Future<void> _resumeLoop() async {
    if (_resuming) return;
    _resuming = true;
    var delay = const Duration(seconds: 1);
    try {
      while (!_ended && !isAttached) {
        await Future<void>.delayed(delay);
        if (_ended) return;
        try {
          final r = await resume!(sid);
          if (r != null && !_ended) {
            _dialerNonce = r.dialerNonce;
            _listenerNonce = r.listenerNonce;
            _bind(r.peer);
            _events.add(const SignalingResumed());
            _flush();
            return;
          }
        } on Object catch (e) {
          _log.d('resume attempt failed: $e');
        }
        delay = Duration(seconds: (delay.inSeconds * 2).clamp(1, 10));
      }
    } finally {
      _resuming = false;
    }
  }

  void _tick() {
    final p = _peer;
    if (_ended || p == null || p.isClosed) return;
    if (DateTime.now().difference(p.lastActivity) > silenceTimeout) {
      _log.d('signaling silent, dropping socket');
      unawaited(p.close());
      return;
    }
    p.send(const SigPing());
  }

  void _finish() {
    if (_ended) return;
    _ended = true;
    _keepalive?.cancel();
    final p = _peer;
    _peer = null;
    if (p != null) unawaited(p.close());
    _outbox.clear();
    unawaited(_events.close());
    if (!_closed.isCompleted) _closed.complete();
  }
}
