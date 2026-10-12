import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/thelxis_id.dart';
import 'package:thelxis/net/dialer.dart';
import 'package:thelxis/net/handshake.dart';
import 'package:thelxis/net/listener.dart';
import 'package:thelxis/net/net_address.dart';
import 'package:thelxis/net/peer_identity.dart';
import 'package:thelxis/net/signaling_channel.dart';
import 'package:thelxis/net/ws_peer.dart';
import 'package:thelxis/protocol/signaling_messages.dart';

import 'support/fakes.dart';

Future<Identity> _identity(int fill) =>
    Identity.fromSeed(List<int>.generate(32, (i) => (i * 7 + fill) & 0xff));

LocalPeerInfo _info(String name) => LocalPeerInfo(name: name, os: 'linux', app: '0.1.0');

void main() {
  late Identity alice; // dialer / viewer
  late Identity bob; // listener / host
  late FakeConnectivity bobNet;
  late SignalingListener listener;
  late Dialer dialer;

  setUp(() async {
    alice = await _identity(1);
    bob = await _identity(2);
    bobNet = FakeConnectivity(addresses: ['127.0.0.1:1']);
    listener = SignalingListener(
      identity: bob,
      connectivity: bobNet,
      localInfo: () => _info('Bob PC'),
      admit: (peer, want) => null,
      maxUnauthPerIp: 3,
    );
    expect(
      await listener.start(port: 0, address: InternetAddress.loopbackIPv4),
      isTrue,
    );
    dialer = Dialer(
      identity: alice,
      localInfo: () => _info('Alice Mac'),
      advertisedAddresses: () => const ['10.0.0.5:47100'],
    );
  });

  tearDown(() async {
    await listener.dispose();
  });

  NetAddress target() => NetAddress('127.0.0.1', listener.port);

  test('Thelxis ID derivation matches the Python vector', () {
    final pub = List<int>.generate(32, (i) => i);
    expect(thelxisIdFromPublicKey(pub), 'CC6WTAB6RGSPD48J');
    expect(thelxisIdFromPublicKey(List<int>.filled(32, 0xff)), 'NYB16XGFE9HNZFDM');
    expect(formatThelxisId('CC6WTAB6RGSPD48J'), 'CC6W-TAB6-RGSP-D48J');
  });

  test('handshake completes and both sides learn the verified identity', () async {
    final incomingFuture = listener.incoming.first;
    final result = await dialer.dial(
      addresses: [target()],
      want: HelloWant.control,
      expectedId: bob.id,
    );
    final incoming = await incomingFuture;

    expect(result.peer.id, bob.id);
    expect(result.peer.name, 'Bob PC');
    expect(result.connectedTo, target());
    expect(incoming.peer.id, alice.id);
    expect(incoming.peer.name, 'Alice Mac');
    expect(incoming.peer.addresses, ['10.0.0.5:47100']);
    expect(incoming.want, HelloWant.control);
    expect(incoming.sid, result.sid);
    expect(incoming.dialed, target().hostPort);
    expect(result.turn, isNotNull);
    expect(result.turn!.udpPort, 47100);
    expect(bobNet.issued, hasLength(1));
    expect(bobNet.listening, isTrue);

    result.channel.dispose();
    incoming.channel.dispose();
    await incoming.channel.closed;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(bobNet.revoked, hasLength(1));
  });

  test('reverse mode is reported to the listener', () async {
    final incomingFuture = listener.incoming.first;
    final result = await dialer.dial(addresses: [target()], want: HelloWant.beControlled);
    final incoming = await incomingFuture;
    expect(incoming.want, HelloWant.beControlled);
    result.channel.dispose();
    incoming.channel.dispose();
  });

  test('wrong expected ID is a hard identity-mismatch failure', () async {
    final stranger = await _identity(9);
    await expectLater(
      dialer.dial(addresses: [target()], want: HelloWant.control, expectedId: stranger.id),
      throwsA(isA<DialException>()
          .having((e) => e.kind, 'kind', DialFailure.identityMismatch)
          .having((e) => e.actualId, 'actualId', bob.id)),
    );
  });

  test('a remembered key that differs is a hard identity-mismatch failure', () async {
    final stranger = await _identity(9);
    await expectLater(
      dialer.dial(
        addresses: [target()],
        want: HelloWant.control,
        expectedId: bob.id,
        expectedKey: stranger.publicKeyB64,
      ),
      throwsA(isA<DialException>().having((e) => e.kind, 'kind', DialFailure.identityMismatch)),
    );
  });

  test('the remembered key of the right device connects', () async {
    final incomingFuture = listener.incoming.first;
    final result = await dialer.dial(
      addresses: [target()],
      want: HelloWant.control,
      expectedId: bob.id,
      expectedKey: bob.publicKeyB64,
    );
    final incoming = await incomingFuture;
    expect(result.peer.id, bob.id);
    result.channel.dispose();
    incoming.channel.dispose();
  });

  test('probe returns the verified identity without creating a session', () async {
    final peer = await dialer.probe([target()]);
    expect(peer.id, bob.id);
    expect(peer.name, 'Bob PC');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(bobNet.issued, isEmpty);
  });

  test('happy eyeballs skips a dead address and finds the live one', () async {
    final dead = NetAddress('127.0.0.1', 1);
    final fast = Dialer(
      identity: alice,
      localInfo: () => _info('Alice Mac'),
      advertisedAddresses: () => const [],
      stagger: const Duration(milliseconds: 20),
    );
    final result = await fast.dial(
      addresses: [dead, target()],
      want: HelloWant.control,
      expectedId: bob.id,
    );
    expect(result.connectedTo, target());
    result.channel.dispose();
  });

  test('all addresses dead gives unreachable', () async {
    await expectLater(
      dialer.dial(addresses: [NetAddress('127.0.0.1', 1)], want: HelloWant.control),
      throwsA(isA<DialException>().having((e) => e.kind, 'kind', DialFailure.unreachable)),
    );
  });

  test('admit callback can refuse with busy', () async {
    await listener.dispose();
    listener = SignalingListener(
      identity: bob,
      connectivity: bobNet,
      localInfo: () => _info('Bob PC'),
      admit: (peer, want) => 'busy',
    );
    await listener.start(port: 0, address: InternetAddress.loopbackIPv4);
    await expectLater(
      dialer.dial(addresses: [target()], want: HelloWant.control),
      throwsA(isA<DialException>().having((e) => e.kind, 'kind', DialFailure.busy)),
    );
  });

  test('signed SDP round-trips; tampered SDP raises a security failure', () async {
    final incomingFuture = listener.incoming.first;
    final result = await dialer.dial(
      addresses: [target()],
      want: HelloWant.control,
      expectedId: bob.id,
    );
    final incoming = await incomingFuture;

    final viewerEvents = EventLog(result.channel.events);
    final hostEvents = EventLog(incoming.channel.events);

    final gotOffer = viewerEvents.waitFor<RemoteSdp>();
    await incoming.channel.sendOffer('v=0\r\na=fingerprint:sha-256 AA:BB\r\n');
    final offer = await gotOffer;
    expect(offer.type, 'offer');
    expect(offer.sdp, contains('fingerprint'));

    final gotAnswer = hostEvents.waitFor<RemoteSdp>();
    await result.channel.sendAnswer('v=0\r\nanswer\r\n');
    expect((await gotAnswer).type, 'answer');

    final gotCandidate = hostEvents.waitFor<RemoteCandidate>();
    result.channel.sendCandidate(candidate: 'candidate:1 1 udp 1 1.2.3.4 5 typ host', sdpMid: '0', sdpMLineIndex: 0);
    expect((await gotCandidate).sdpMLineIndex, 0);

    result.channel.dispose();
    incoming.channel.dispose();
  });

  test('SDP signed for different content fails verification', () async {
    final ok = await signPayload(
      alice,
      sdpPayload(dialerNonce: 'a', listenerNonce: 'b', type: 'answer', sdp: 'sdp-1'),
    );
    Future<bool> check(String type, String sdp, String nD, String nL) => verifyPayload(
          peerKey: alice.publicKeyB64,
          signature: ok,
          payload: sdpPayload(dialerNonce: nD, listenerNonce: nL, type: type, sdp: sdp),
        );
    expect(await check('answer', 'sdp-1', 'a', 'b'), isTrue);
    expect(await check('answer', 'sdp-2', 'a', 'b'), isFalse);
    expect(await check('offer', 'sdp-1', 'a', 'b'), isFalse);
    expect(await check('answer', 'sdp-1', 'x', 'b'), isFalse);
    expect(await check('answer', 'sdp-1', 'a', 'x'), isFalse);
    expect(
      await verifyPayload(peerKey: bob.publicKeyB64, signature: ok, payload: sdpPayload(dialerNonce: 'a', listenerNonce: 'b', type: 'answer', sdp: 'sdp-1')),
      isFalse,
    );
  });

  test('a forged SDP on the wire triggers SignatureFailure and bye', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final serverSide = Completer<WsPeer>();
    server.listen((req) async {
      serverSide.complete(WsPeer(await WebSocketTransformer.upgrade(req)));
    });
    final raw = await WebSocket.connect('ws://127.0.0.1:${server.port}/');
    final channel = SignalingChannel(
      sid: 's1',
      identity: bob,
      role: SignalingRole.listener,
      peerKey: alice.publicKeyB64,
      peer: await serverSide.future,
      initialDialerNonce: 'nD',
      initialListenerNonce: 'nL',
    );
    final events = EventLog(channel.events);
    final rawMessages = <Map<String, dynamic>>[];
    raw.listen((d) => rawMessages.add(jsonDecode(d as String) as Map<String, dynamic>));

    final goodSig = await signPayload(
      alice,
      sdpPayload(dialerNonce: 'nD', listenerNonce: 'nL', type: 'answer', sdp: 'GOOD'),
    );
    raw.add(jsonEncode({'t': 'signal', 'data': {'type': 'answer', 'sdp': 'GOOD', 'sig': goodSig}}));
    expect((await events.waitFor<RemoteSdp>()).sdp, 'GOOD');

    final failure = events.waitFor<SignatureFailure>();
    raw.add(jsonEncode({'t': 'signal', 'data': {'type': 'answer', 'sdp': 'EVIL', 'sig': goodSig}}));
    await failure;
    await channel.closed.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(rawMessages.any((m) => m['t'] == 'bye' && m['reason'] == 'error'), isTrue);
    await raw.close();
  });

  test('closing a peer finishes the close handshake and leaves no long timer behind', () async {
    final longTimers = <Timer>[];
    await runZoned(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final accepted = Completer<WsPeer>();
      server.listen((req) async {
        accepted.complete(WsPeer(await WebSocketTransformer.upgrade(req)));
      });
      final client = WsPeer(await WebSocket.connect('ws://127.0.0.1:${server.port}/'));
      final peer = await accepted.future;
      final clientSawClose = Completer<void>();
      client.listen(onMessage: (_) {}, onClose: clientSawClose.complete);

      await peer.close();
      await clientSawClose.future.timeout(const Duration(seconds: 3));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }, zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, f) {
        final timer = parent.createTimer(zone, duration, f);
        if (duration >= const Duration(seconds: 1)) longTimers.add(timer);
        return timer;
      },
    ));
    // dart:io arms a five second timer when it closes first and never sees the
    // peer's close frame; cancelling the subscription early did exactly that.
    expect(longTimers.where((t) => t.isActive), isEmpty);
  });

  test('unauthenticated connection flood from one IP gets rate_limited', () async {
    final sockets = <WebSocket>[];
    final errors = <String>[];
    for (var i = 0; i < 5; i++) {
      final ws = await WebSocket.connect('ws://127.0.0.1:${listener.port}/thelxis');
      sockets.add(ws);
      ws.listen((d) {
        final m = jsonDecode(d as String) as Map<String, dynamic>;
        if (m['t'] == 'error') errors.add(m['code'] as String);
      });
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(errors, contains('rate_limited'));
    for (final s in sockets) {
      await s.close();
    }
  });

  test('a session survives a socket drop: dialer resumes and signals still verify', () async {
    final incomingFuture = listener.incoming.first;
    final result = await dialer.dial(
      addresses: [target()],
      want: HelloWant.control,
      expectedId: bob.id,
    );
    final incoming = await incomingFuture;
    final viewerEvents = EventLog(result.channel.events);
    final hostEvents = EventLog(incoming.channel.events);

    final detached = viewerEvents.waitFor<SignalingDetached>();
    final resumed = viewerEvents.waitFor<SignalingResumed>();
    final hostResumed = hostEvents.waitFor<SignalingResumed>();
    incoming.channel.debugDropSocket();
    await detached;
    await resumed;
    await hostResumed;

    final gotOffer = viewerEvents.waitFor<RemoteSdp>();
    await incoming.channel.sendOffer('restart-offer');
    expect((await gotOffer).sdp, 'restart-offer');

    result.channel.dispose();
    incoming.channel.dispose();
  });
}
