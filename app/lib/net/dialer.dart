import 'dart:async';
import 'dart:io';

import '../core/identity.dart';
import '../core/log.dart';
import '../protocol/signaling_messages.dart';
import 'handshake.dart';
import 'net_address.dart';
import 'peer_identity.dart';
import 'signaling_channel.dart';
import 'ws_peer.dart';

const _log = Logger('dialer');

enum DialFailure {
  /// No address answered.
  unreachable,

  /// The peer's key does not hash to the expected ID: possible interception.
  identityMismatch,

  /// A signature in the handshake did not verify.
  badSignature,
  notAccepting,
  busy,
  rateLimited,
  version,
  timeout,
  protocol,
}

class DialException implements Exception {
  const DialException(this.kind, this.message, {this.actualId});

  final DialFailure kind;
  final String message;

  /// For [DialFailure.identityMismatch]: the ID the peer actually proved.
  final String? actualId;

  @override
  String toString() => 'DialException($kind: $message)';
}

/// Outcome of a successful dial.
class DialResult {
  const DialResult({
    required this.peer,
    required this.sid,
    required this.channel,
    required this.connectedTo,
    this.turn,
  });

  final PeerIdentity peer;
  final String sid;
  final SignalingChannel channel;

  /// The address that won the race; the TURN host for ICE.
  final NetAddress connectedTo;
  final TurnInfo? turn;
}

class _Established {
  _Established(this.peer, this.ws, this.sid, this.turn, this.dialerNonce, this.listenerNonce, this.address);
  final PeerIdentity peer;
  final WsPeer ws;
  final String sid;
  final TurnInfo? turn;
  final String dialerNonce;
  final String listenerNonce;
  final NetAddress address;
}

/// Opens outbound signaling connections (PROTOCOL.md sections 3 and 4.1).
class Dialer {
  Dialer({
    required this.identity,
    required this.localInfo,
    required this.advertisedAddresses,
    this.stagger = const Duration(milliseconds: 250),
    this.gatewayDelay = const Duration(milliseconds: 500),
    this.connectTimeout = const Duration(seconds: 8),
    this.handshakeTimeout = const Duration(seconds: 20),
  });

  final Identity identity;
  final LocalPeerInfo Function() localInfo;
  final List<String> Function() advertisedAddresses;
  final Duration stagger;

  /// Gateway routes (PROTOCOL.md section 11) start this much after the first
  /// direct attempt, so a reachable device never needs the office gateway.
  final Duration gatewayDelay;
  final Duration connectTimeout;
  final Duration handshakeTimeout;

  /// Connects to the first address that completes a handshake with the peer
  /// holding [expectedId]. When [expectedId] is null the caller must have
  /// confirmed the peer via [probe] first. [expectedKey] (the full public key
  /// remembered from an earlier session) pins the peer beyond the 80-bit ID.
  Future<DialResult> dial({
    required List<NetAddress> addresses,
    required HelloWant want,
    String? expectedId,
    String? expectedKey,
  }) async {
    // A gateway only pipes bytes: without a known ID to verify there would be
    // nothing to stop it (or anything it can reach) impersonating the target.
    addresses = _usableRoutes(addresses, expectedId);
    final e = await _race(
      addresses,
      (addr) => _attempt(addr, want: want, expectedId: expectedId, expectedKey: expectedKey),
    );
    final channel = SignalingChannel(
      sid: e.sid,
      identity: identity,
      role: SignalingRole.dialer,
      peerKey: e.peer.key,
      peer: e.ws,
      initialDialerNonce: e.dialerNonce,
      initialListenerNonce: e.listenerNonce,
      resume: (sid) => _resume(sid, e.peer, [e.address, ...addresses], want),
    );
    return DialResult(
      peer: e.peer,
      sid: e.sid,
      channel: channel,
      connectedTo: e.address,
      turn: e.turn,
    );
  }

  /// Trust-on-first-use helper: performs the first half of the handshake and
  /// returns the listener's verified identity without sending `hello_ack`, so
  /// the user can confirm it before anything is revealed or accepted.
  Future<PeerIdentity> probe(List<NetAddress> addresses) async {
    addresses = _usableRoutes(addresses, null);
    final e = await _race(
      addresses,
      (addr) => _attempt(addr, want: HelloWant.control, probeOnly: true),
    );
    await e.ws.close();
    return e.peer;
  }

  /// Drops gateway routes that cannot be verified: no expected ID, or a route
  /// meant for another device.
  static List<NetAddress> _usableRoutes(List<NetAddress> addresses, String? expectedId) => [
        for (final a in addresses)
          if (!a.isViaGateway || (expectedId != null && a.viaId == expectedId)) a,
      ];

  Future<ResumedConnection?> _resume(
    String sid,
    PeerIdentity peer,
    List<NetAddress> addresses,
    HelloWant want,
  ) async {
    final e = await _race(
      addresses,
      (addr) => _attempt(
        addr,
        want: want,
        expectedId: peer.id,
        expectedKey: peer.key,
        resumeSid: sid,
      ),
    );
    return ResumedConnection(e.ws, e.dialerNonce, e.listenerNonce);
  }

  /// When each attempt of [addresses] starts, relative to the dial: direct
  /// addresses at i * [stagger]; gateway routes after the direct ones, at
  /// [gatewayDelay] + j * [stagger] (immediately when there is nothing direct).
  List<Duration> raceSchedule(List<NetAddress> addresses) {
    final hasDirect = addresses.any((a) => !a.isViaGateway);
    var direct = 0;
    var via = 0;
    return [
      for (final a in addresses)
        if (a.isViaGateway)
          (hasDirect ? gatewayDelay : Duration.zero) + stagger * via++
        else
          stagger * direct++,
    ];
  }

  /// Happy eyeballs: attempts start on the [raceSchedule]; the first success
  /// wins and every other attempt is torn down.
  Future<_Established> _race(
    List<NetAddress> addresses,
    Future<_Established> Function(NetAddress) attempt,
  ) {
    if (addresses.isEmpty) {
      throw const DialException(DialFailure.unreachable, 'No address to connect to');
    }
    final done = Completer<_Established>();
    final errors = <DialException>[];
    var pending = addresses.length;
    var finished = false;
    final timers = <Timer>[];

    void settle(_Established? ok, DialException? err) {
      if (ok != null) {
        if (finished) {
          unawaited(ok.ws.close());
          return;
        }
        finished = true;
        for (final t in timers) {
          t.cancel();
        }
        done.complete(ok);
        return;
      }
      errors.add(err!);
      pending--;
      if (pending == 0 && !finished) {
        finished = true;
        done.completeError(_mostRelevant(errors));
      }
    }

    final schedule = raceSchedule(addresses);
    for (var i = 0; i < addresses.length; i++) {
      final addr = addresses[i];
      void run() {
        if (finished) {
          pending--;
          return;
        }
        attempt(addr).then((e) => settle(e, null), onError: (Object e) {
          settle(null, _asDialException(e));
        });
      }

      if (schedule[i] == Duration.zero) {
        run();
      } else {
        timers.add(Timer(schedule[i], run));
      }
    }
    return done.future;
  }

  static DialException _mostRelevant(List<DialException> errors) {
    const order = [
      DialFailure.identityMismatch,
      DialFailure.badSignature,
      DialFailure.notAccepting,
      DialFailure.busy,
      DialFailure.rateLimited,
      DialFailure.version,
      DialFailure.protocol,
      DialFailure.timeout,
      DialFailure.unreachable,
    ];
    for (final kind in order) {
      for (final e in errors) {
        if (e.kind == kind) return e;
      }
    }
    return errors.first;
  }

  static DialException _asDialException(Object e) {
    if (e is DialException) return e;
    if (e is TimeoutException) {
      return const DialException(DialFailure.timeout, 'Connection timed out');
    }
    if (e is SocketException || e is WebSocketException || e is HttpException) {
      return DialException(DialFailure.unreachable, 'Could not connect');
    }
    if (e is WsClosedException) {
      return const DialException(DialFailure.protocol, 'Connection closed during handshake');
    }
    return DialException(DialFailure.protocol, 'Unexpected error');
  }

  Future<_Established> _attempt(
    NetAddress addr, {
    required HelloWant want,
    String? expectedId,
    String? expectedKey,
    String? resumeSid,
    bool probeOnly = false,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = connectTimeout
      ..findProxy = ((_) => 'DIRECT');
    final WebSocket socket;
    try {
      socket = await WebSocket.connect(
        addr.signalingUri.toString(),
        customClient: client,
        compression: CompressionOptions.compressionOff,
      ).timeout(connectTimeout);
    } on Object {
      client.close(force: true);
      rethrow;
    }
    final ws = WsPeer(socket, remoteIp: addr.host);
    try {
      return await _handshake(
        ws,
        addr,
        want: want,
        expectedId: expectedId,
        expectedKey: expectedKey,
        resumeSid: resumeSid,
        probeOnly: probeOnly,
      ).timeout(handshakeTimeout);
    } on Object {
      unawaited(ws.close());
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<_Established> _handshake(
    WsPeer ws,
    NetAddress addr, {
    required HelloWant want,
    String? expectedId,
    String? expectedKey,
    String? resumeSid,
    required bool probeOnly,
  }) async {
    final info = localInfo();
    final nonce = generateNonce();
    ws.send(HsHello(
      isListener: false,
      key: identity.publicKeyB64,
      name: info.name,
      os: info.os,
      app: info.app,
      want: want,
      nonce: nonce,
      addresses: advertisedAddresses(),
      dialed: addr.hostPort,
      resume: resumeSid,
    ));

    final reply = await ws.next(timeout: handshakeTimeout);
    if (reply is SigError) throw _fromError(reply);
    if (reply is! HsHello || !reply.isListener) {
      throw const DialException(DialFailure.protocol, 'Unexpected handshake reply');
    }
    final listener = PeerIdentity.fromHello(
      key: reply.key,
      name: reply.name,
      os: reply.os,
      app: reply.app,
      addresses: reply.addresses,
    );
    final sig = reply.sig;
    if (listener == null || sig == null || reply.nonce.length < 16 || reply.nonce.length > 128) {
      throw const DialException(DialFailure.protocol, 'Malformed listener hello');
    }
    final sigOk = await verifyPayload(
      peerKey: listener.key,
      signature: sig,
      payload: listenerHandshakePayload(
        dialerNonce: nonce,
        listenerNonce: reply.nonce,
        dialerKey: identity.publicKeyB64,
      ),
    );
    if (!sigOk) {
      throw const DialException(DialFailure.badSignature, 'Listener signature invalid');
    }
    if ((expectedId != null && listener.id != expectedId) ||
        (expectedKey != null && listener.key != expectedKey)) {
      _log.w('identity mismatch at ${addr.host}');
      throw DialException(
        DialFailure.identityMismatch,
        'The device at this address is not the one you expected.',
        actualId: listener.id,
      );
    }
    if (probeOnly) {
      return _Established(listener, ws, '', null, nonce, reply.nonce, addr);
    }

    ws.send(HsAck(await signPayload(
      identity,
      dialerHandshakePayload(
        dialerNonce: nonce,
        listenerNonce: reply.nonce,
        listenerKey: listener.key,
      ),
    )));
    final session = await ws.next(timeout: handshakeTimeout);
    if (session is SigError) throw _fromError(session);
    if (session is! HsSession) {
      throw const DialException(DialFailure.protocol, 'Expected session');
    }
    return _Established(listener, ws, session.sid, session.turn, nonce, reply.nonce, addr);
  }

  static DialException _fromError(SigError e) {
    switch (e.code) {
      case 'not_accepting':
        return const DialException(DialFailure.notAccepting, 'This device is not accepting connections.');
      case 'busy':
        return const DialException(DialFailure.busy, 'This device is busy.');
      case 'rate_limited':
        return const DialException(DialFailure.rateLimited, 'Too many attempts. Try again in a minute.');
      case 'version':
        return const DialException(DialFailure.version, 'The other device runs an incompatible version.');
      case 'bad_signature':
        return const DialException(DialFailure.badSignature, 'The other device rejected our signature.');
      case 'not_found':
        return const DialException(DialFailure.unreachable, 'The gateway cannot find that device.');
      default:
        return DialException(DialFailure.protocol, 'Connection refused (${e.code})');
    }
  }
}
