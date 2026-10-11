import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../core/identity.dart';
import '../core/log.dart';
import '../core/thelxis_id.dart';
import '../protocol/signaling_messages.dart';
import 'connectivity/connectivity.dart';
import 'gateway.dart';
import 'handshake.dart';
import 'peer_identity.dart';
import 'signaling_channel.dart';
import 'ws_peer.dart';

const _log = Logger('listener');

/// A peer that completed the signed handshake against our listener.
class IncomingPeer {
  const IncomingPeer({
    required this.peer,
    required this.want,
    required this.sid,
    required this.channel,
    required this.remoteIp,
    this.dialed,
    this.grant,
  });

  final PeerIdentity peer;
  final HelloWant want;
  final String sid;
  final SignalingChannel channel;
  final String remoteIp;

  /// The address the dialer says it connected to.
  final String? dialed;

  /// TURN credentials handed to the dialer; the session must revoke them when
  /// it ends.
  final TurnGrant? grant;
}

/// Decides whether a handshaken peer may proceed. Returns an error code
/// (`not_accepting`, `busy`, ...) or null to accept.
typedef AdmitCallback = String? Function(PeerIdentity peer, HelloWant want);

/// Accepts signaling WebSockets on TCP 47100 (PROTOCOL.md sections 4 and 8).
class SignalingListener {
  SignalingListener({
    required this.identity,
    required this.connectivity,
    required this.localInfo,
    required this.admit,
    this.helloTimeout = const Duration(seconds: 10),
    this.handshakeTimeout = const Duration(seconds: 20),
    this.maxUnauthPerIp = 4,
    this.maxHandshakesPerMinute = 30,
  });

  final Identity identity;
  final Connectivity connectivity;
  final LocalPeerInfo Function() localInfo;
  final AdmitCallback admit;
  final Duration helloTimeout;
  final Duration handshakeTimeout;
  final int maxUnauthPerIp;
  final int maxHandshakesPerMinute;

  /// Serves `/thelxis/via/<ID>` while the office gateway is on; null answers
  /// such requests with 404, exactly like any unknown path.
  GatewayHandler? gatewayHandler;

  final _incoming = StreamController<IncomingPeer>.broadcast();
  final Map<String, SignalingChannel> _live = {};
  final Map<String, int> _unauthByIp = {};
  final Queue<DateTime> _handshakeTimes = Queue();
  HttpServer? _server;
  static const _uuid = Uuid();

  Stream<IncomingPeer> get incoming => _incoming.stream;

  bool get isListening => _server != null;

  /// The TCP port actually bound (0 when stopped).
  int get port => _server?.port ?? 0;

  /// Binds dual-stack when possible. Returns false (and logs) on failure so
  /// the app keeps working as a dialer.
  Future<bool> start({
    int port = ThelxisPorts.signalingTcp,
    InternetAddress? address,
  }) async {
    if (_server != null) return true;
    HttpServer? server;
    if (address != null) {
      server = await _tryBind(address, port, false);
    } else {
      server = await _tryBind(InternetAddress.anyIPv6, port, false);
      server ??= await _tryBind(InternetAddress.anyIPv4, port, false);
    }
    if (server == null) {
      connectivity.setListening(false);
      return false;
    }
    _server = server;
    server.listen(
      (req) => unawaited(_handleRequest(req)),
      onError: (Object e) => _log.w('server error', e),
    );
    connectivity.setListening(true);
    _log.i('listening on port ${server.port}');
    return true;
  }

  Future<HttpServer?> _tryBind(InternetAddress address, int port, bool v6Only) async {
    try {
      return await HttpServer.bind(address, port, v6Only: v6Only, shared: false);
    } on SocketException catch (e) {
      _log.w('bind ${address.address}:$port failed', e);
      return null;
    }
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    connectivity.setListening(false);
    await s?.close(force: true);
    for (final c in _live.values.toList()) {
      c.dispose();
    }
    _live.clear();
  }

  Future<void> dispose() async {
    await stop();
    await _incoming.close();
  }

  Future<void> _handleRequest(HttpRequest req) async {
    final ip = _remoteIp(req);
    final viaId = _viaTarget(req.uri.path);
    final isGateway = viaId != null && gatewayHandler != null;
    if ((req.uri.path != '/thelxis' && !isGateway) || !WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(
        req,
        compression: CompressionOptions.compressionOff,
      );
    } on Object catch (e) {
      _log.d('upgrade failed: $e');
      return;
    }
    if (isGateway) {
      // Same rate limits as handshakes; the pipe itself is limited by the gateway.
      if (!_admitConnection(ip)) {
        socket.add('{"t":"error","code":"rate_limited","message":"Too many connections"}');
        unawaited(socket.close(WebSocketStatus.policyViolation, 'rate_limited'));
        return;
      }
      await gatewayHandler!(socket, viaId, ip);
      return;
    }
    final peer = WsPeer(socket, remoteIp: ip);
    if (!_admitConnection(ip)) {
      peer.send(const SigError('rate_limited', 'Too many connections'));
      await peer.close(WebSocketStatus.policyViolation, 'rate_limited');
      return;
    }
    _unauthByIp[ip] = (_unauthByIp[ip] ?? 0) + 1;
    try {
      final result = await _handshake(peer, ip).timeout(handshakeTimeout);
      if (result != null) _incoming.add(result);
    } on _Reject catch (r) {
      peer.send(SigError(r.code, r.message));
      await peer.close(WebSocketStatus.policyViolation, r.code);
    } on TimeoutException {
      await peer.close(WebSocketStatus.policyViolation, 'timeout');
    } on WsClosedException {
      // The dialer went away mid-handshake.
    } on Object catch (e, st) {
      _log.e('handshake crashed', e, st);
      await peer.close(WebSocketStatus.internalServerError, 'error');
    } finally {
      final n = (_unauthByIp[ip] ?? 1) - 1;
      if (n <= 0) {
        _unauthByIp.remove(ip);
      } else {
        _unauthByIp[ip] = n;
      }
    }
  }

  bool _admitConnection(String ip) {
    if ((_unauthByIp[ip] ?? 0) >= maxUnauthPerIp) return false;
    final now = DateTime.now();
    while (_handshakeTimes.isNotEmpty &&
        now.difference(_handshakeTimes.first) > const Duration(minutes: 1)) {
      _handshakeTimes.removeFirst();
    }
    if (_handshakeTimes.length >= maxHandshakesPerMinute) return false;
    _handshakeTimes.add(now);
    return true;
  }

  /// Runs the listener half of PROTOCOL.md 4.1. Returns null for a resumed
  /// session (the existing channel was re-attached).
  Future<IncomingPeer?> _handshake(WsPeer ws, String ip) async {
    final first = await ws.next(timeout: helloTimeout);
    if (first is! HsHello || first.isListener) {
      throw const _Reject('error', 'Expected dialer hello');
    }
    final hello = first;
    if (hello.version != 2) {
      throw const _Reject('version', 'Unsupported protocol version');
    }
    final want = hello.want;
    final nonce = hello.nonce;
    if (want == null || nonce.length < 16 || nonce.length > 128) {
      throw const _Reject('error', 'Malformed hello');
    }
    final dialer = PeerIdentity.fromHello(
      key: hello.key,
      name: hello.name,
      os: hello.os,
      app: hello.app,
      addresses: hello.addresses,
    );
    if (dialer == null) throw const _Reject('error', 'Invalid key');
    if (dialer.key == identity.publicKeyB64) {
      throw const _Reject('error', 'Cannot connect to self');
    }

    final resumeSid = hello.resume;
    final existing = resumeSid == null ? null : _live[resumeSid];
    if (resumeSid != null && (existing == null || existing.peerKey != dialer.key)) {
      throw const _Reject('not_accepting', 'Unknown session');
    }

    final listenerNonce = generateNonce();
    final info = localInfo();
    final sig = await signPayload(
      identity,
      listenerHandshakePayload(
        dialerNonce: nonce,
        listenerNonce: listenerNonce,
        dialerKey: dialer.key,
      ),
    );
    ws.send(HsHello(
      isListener: true,
      key: identity.publicKeyB64,
      name: info.name,
      os: info.os,
      app: info.app,
      nonce: listenerNonce,
      addresses: connectivity.advertisedAddresses(),
      sig: sig,
    ));

    final ack = await ws.next(timeout: handshakeTimeout);
    if (ack is! HsAck) throw const _Reject('error', 'Expected hello_ack');
    final ackOk = await verifyPayload(
      peerKey: dialer.key,
      signature: ack.sig,
      payload: dialerHandshakePayload(
        dialerNonce: nonce,
        listenerNonce: listenerNonce,
        listenerKey: identity.publicKeyB64,
      ),
    );
    if (!ackOk) throw const _Reject('bad_signature', 'Handshake signature invalid');

    if (existing != null) {
      ws.send(HsSession(resumeSid!, null));
      existing.attach(ws, dialerNonce: nonce, listenerNonce: listenerNonce);
      return null;
    }

    final denied = admit(dialer, want);
    if (denied != null) throw _Reject(denied, 'Not accepting connections');

    final sid = _uuid.v4();
    final grant = connectivity.issueTurnGrant(dialedAddress: hello.dialed);
    ws.send(HsSession(sid, grant == null ? null : TurnInfo(
      username: grant.username,
      credential: grant.credential,
      udpPort: grant.udpPort,
      tcpPort: grant.tcpPort,
    )));

    final channel = SignalingChannel(
      sid: sid,
      identity: identity,
      role: SignalingRole.listener,
      peerKey: dialer.key,
      peer: ws,
      initialDialerNonce: nonce,
      initialListenerNonce: listenerNonce,
    );
    _live[sid] = channel;
    unawaited(channel.closed.then((_) {
      _live.remove(sid);
      if (grant != null) connectivity.revokeTurnGrant(grant);
    }));
    return IncomingPeer(
      peer: dialer,
      want: want,
      sid: sid,
      channel: channel,
      remoteIp: ip,
      dialed: hello.dialed,
      grant: grant,
    );
  }

  /// The target ID of `/thelxis/via/<ID>` (dashes allowed), or null.
  static String? _viaTarget(String path) {
    const prefix = '/thelxis/via/';
    if (!path.startsWith(prefix)) return null;
    try {
      return parseThelxisId(Uri.decodeComponent(path.substring(prefix.length)));
    } on ArgumentError {
      return null;
    }
  }

  static String _remoteIp(HttpRequest req) {
    final raw = req.connectionInfo?.remoteAddress.address ?? '';
    return raw.startsWith('::ffff:') ? raw.substring(7) : raw;
  }
}

class _Reject implements Exception {
  const _Reject(this.code, this.message);
  final String code;
  final String message;
}
