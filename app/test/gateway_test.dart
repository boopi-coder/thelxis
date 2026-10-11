import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/log.dart';
import 'package:thelxis/net/dialer.dart';
import 'package:thelxis/net/discovery.dart';
import 'package:thelxis/net/gateway.dart';
import 'package:thelxis/net/listener.dart';
import 'package:thelxis/net/net_address.dart';
import 'package:thelxis/net/peer_identity.dart';
import 'package:thelxis/protocol/signaling_messages.dart';

import 'support/fakes.dart';

Future<Identity> _identity(int fill) =>
    Identity.fromSeed(List<int>.generate(32, (i) => (i * 7 + fill) & 0xff));

LocalPeerInfo _info(String name) => LocalPeerInfo(name: name, os: 'linux', app: '0.2.0');

DiscoveredPeer _peer(Identity id, int port, {String host = '127.0.0.1'}) => DiscoveredPeer(
      id: id.id,
      key: id.publicKeyB64,
      name: 'Target',
      os: 'windows',
      host: host,
      port: port,
      lastSeen: DateTime.now(),
    );

/// A stand-in for the target device: an HTTP server that upgrades
/// `/thelxis` and records / scripts the frames.
class _FakeTarget {
  late HttpServer server;
  final List<dynamic> received = [];
  WebSocket? socket;
  final Completer<void> connected = Completer<void>();
  final Completer<void> socketClosed = Completer<void>();
  int connections = 0;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      if (req.uri.path != '/thelxis') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      connections++;
      socket = ws;
      ws.listen(received.add, onDone: () {
        if (!socketClosed.isCompleted) socketClosed.complete();
      });
      if (!connected.isCompleted) connected.complete();
    });
  }

  int get port => server.port;
  Future<void> stop() => server.close(force: true);
}

void main() {
  Logger.sink = (_, _) {};

  late Identity gw; // the office gateway G
  late Identity viewer; // V
  late Identity target; // T
  late FakeConnectivity gwNet;
  late SignalingListener gateListener;
  late OfficeGateway gateway;
  DiscoveredPeer? lookupResult;
  late List<String> lookups;

  setUp(() async {
    gw = await _identity(3);
    viewer = await _identity(1);
    target = await _identity(2);
    gwNet = FakeConnectivity(addresses: ['127.0.0.1:1']);
    lookups = [];
    lookupResult = null;
    gateway = OfficeGateway(
      connectivity: gwNet,
      findTarget: (id) async {
        lookups.add(id);
        return lookupResult;
      },
    );
    gateListener = SignalingListener(
      identity: gw,
      connectivity: gwNet,
      localInfo: () => _info('Gateway'),
      admit: (peer, want) => null,
    )..gatewayHandler = gateway.handle;
    expect(await gateListener.start(port: 0, address: InternetAddress.loopbackIPv4), isTrue);
  });

  tearDown(() async {
    await gateListener.dispose();
  });

  String viaUrl(String id) => 'ws://127.0.0.1:${gateListener.port}/thelxis/via/$id';

  group('the pipe', () {
    late _FakeTarget t;
    setUp(() async {
      t = _FakeTarget();
      await t.start();
      lookupResult = _peer(target, t.port);
    });
    tearDown(() => t.stop());

    const hello = '{"t":"hello","v":2,"role":"dialer","key":"K","name":"V","os":"mac","app":"1",'
        '"want":"control","nonce":"n","addresses":[],"dialed":"203.0.113.5:47100"}';

    test('forwards the hello unchanged and pipes frames verbatim in both directions', () async {
      final v = await WebSocket.connect(viaUrl(target.id));
      final fromTarget = <dynamic>[];
      v.listen(fromTarget.add);
      v.add(hello);
      await t.connected.future.timeout(const Duration(seconds: 5));
      await _until(() => t.received.isNotEmpty);
      expect(t.received.first, hello, reason: 'byte for byte');
      expect(lookups, [target.id]);

      // Odd spacing and unicode survive untouched.
      const odd = '{ "t" : "signal",  "data" : {"type":"candidate","candidate":"привет  x"} }';
      t.socket!.add(odd);
      await _until(() => fromTarget.isNotEmpty);
      expect(fromTarget.single, odd);

      const back = '{"t":"hello_ack","sig":"abc"}';
      v.add(back);
      await _until(() => t.received.length == 2);
      expect(t.received[1], back);
      await v.close();
    });

    test('rewrites only session.turn, with a gateway grant for the dialed address', () async {
      final v = await WebSocket.connect(viaUrl(target.id));
      final fromTarget = <String>[];
      v.listen((d) => fromTarget.add(d as String));
      v.add(hello);
      await t.connected.future;
      t.socket!.add(jsonEncode({
        't': 'session',
        'sid': 'sid-1',
        'turn': {'username': 'targetuser', 'credential': 'targetcred', 'udp_port': 47100, 'tcp_port': 47101},
      }));
      await _until(() => fromTarget.isNotEmpty);
      final j = jsonDecode(fromTarget.single) as Map<String, dynamic>;
      expect(j['t'], 'session');
      expect(j['sid'], 'sid-1');
      final turn = TurnInfo.tryParse(j['turn'])!;
      expect(turn.username, startsWith('user'), reason: 'the gateway\'s credentials, not the target\'s');
      expect(turn.credential, 'cred');
      expect((turn.udpPort, turn.tcpPort), (47200, 47201), reason: 'gateway grant ports');
      expect(gwNet.gatewayGrants, [true]);
      expect(gwNet.dialedAddresses, ['203.0.113.5:47100'], reason: 'the viewer\'s dialed field');

      // Closing the pipe revokes the grant.
      await v.close();
      await _until(() => gwNet.revoked.isNotEmpty);
      expect(gwNet.revoked, hasLength(1));
    });

    test('a resumed session (turn null) and other frames pass untouched', () async {
      final v = await WebSocket.connect(viaUrl(target.id));
      final got = <String>[];
      v.listen((d) => got.add(d as String));
      v.add(hello);
      await t.connected.future;
      const resumed = '{"t":"session","sid":"s","turn":null}';
      const sdp = '{"t":"signal","data":{"type":"offer","sdp":"has \\"session\\" inside","sig":"x"}}';
      t.socket!.add(resumed);
      t.socket!.add(sdp);
      await _until(() => got.length == 2);
      expect(got, [resumed, sdp]);
      expect(gwNet.issued, isEmpty);
      await v.close();
    });

    test('closing either side closes the other', () async {
      final v = await WebSocket.connect(viaUrl(target.id));
      final done = Completer<void>();
      v.listen((_) {}, onDone: done.complete);
      v.add(hello);
      await t.connected.future;
      expect(gateway.activePipes, 1);
      await t.socket!.close();
      await done.future.timeout(const Duration(seconds: 5));
      await _until(() => gateway.activePipes == 0);
    });

    test('a viewer closing takes the target connection down with it', () async {
      final v = await WebSocket.connect(viaUrl(target.id));
      v.add(hello);
      await t.connected.future;
      await v.close();
      await t.socketClosed.future.timeout(const Duration(seconds: 5));
    });

    test('the ID in the path may carry dashes', () async {
      final v = await WebSocket.connect(viaUrl(target.formattedId));
      v.add(hello);
      await t.connected.future;
      expect(lookups, [target.id]);
      await v.close();
    });

    test('at most maxPipes at a time; the extra connection is told rate_limited', () async {
      final small = OfficeGateway(connectivity: gwNet, findTarget: (_) async => lookupResult, maxPipes: 1);
      gateListener.gatewayHandler = small.handle;
      final first = await WebSocket.connect(viaUrl(target.id));
      first.add(hello);
      await t.connected.future;
      final second = await WebSocket.connect(viaUrl(target.id));
      final msgs = <String>[];
      final closed = Completer<void>();
      second.listen((d) => msgs.add(d as String), onDone: closed.complete);
      await closed.future.timeout(const Duration(seconds: 5));
      expect((jsonDecode(msgs.single) as Map)['code'], 'rate_limited');
      expect(t.connections, 1);
      await first.close();
    });

    test('garbage instead of a hello is refused and the target is never contacted', () async {
      final v = await WebSocket.connect(viaUrl(target.id));
      final msgs = <String>[];
      final closed = Completer<void>();
      v.listen((d) => msgs.add(d as String), onDone: closed.complete);
      v.add('{"t":"bye"}');
      await closed.future.timeout(const Duration(seconds: 5));
      expect((jsonDecode(msgs.single) as Map)['code'], 'error');
      expect(t.connections, 0);
      expect(lookups, isEmpty);
    });
  });

  group('refusals', () {
    const hello = '{"t":"hello","v":2,"role":"dialer","key":"K","name":"V","os":"mac","app":"1",'
        '"want":"control","nonce":"n","addresses":[],"dialed":"x:1"}';

    test('an unknown target gets not_found and the connection closes', () async {
      lookupResult = null;
      final v = await WebSocket.connect(viaUrl(target.id));
      final msgs = <String>[];
      final closed = Completer<void>();
      v.listen((d) => msgs.add(d as String), onDone: closed.complete);
      v.add(hello);
      await closed.future.timeout(const Duration(seconds: 5));
      expect(jsonDecode(msgs.single), {'t': 'error', 'code': 'not_found', 'message': 'No such device on this network'});
    });

    test('a target that does not answer is not_found too', () async {
      // A port nothing listens on.
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = dead.port;
      await dead.close();
      lookupResult = _peer(target, port);
      final v = await WebSocket.connect(viaUrl(target.id));
      final msgs = <String>[];
      final closed = Completer<void>();
      v.listen((d) => msgs.add(d as String), onDone: closed.complete);
      v.add(hello);
      await closed.future.timeout(const Duration(seconds: 10));
      expect((jsonDecode(msgs.single) as Map)['code'], 'not_found');
    });

    test('the gateway never connects outside the local network, whatever discovery says', () async {
      final t = _FakeTarget();
      await t.start();
      addTearDown(t.stop);
      lookupResult = _peer(target, t.port, host: '8.8.8.8');
      final v = await WebSocket.connect(viaUrl(target.id));
      final msgs = <String>[];
      final closed = Completer<void>();
      v.listen((d) => msgs.add(d as String), onDone: closed.complete);
      v.add(hello);
      await closed.future.timeout(const Duration(seconds: 5));
      expect((jsonDecode(msgs.single) as Map)['code'], 'not_found');
    });

    test('with the gateway off, /thelxis/via/ is a plain 404', () async {
      gateListener.gatewayHandler = null;
      await expectLater(WebSocket.connect(viaUrl(target.id)), throwsA(isA<WebSocketException>()));
    });

    test('a malformed ID in the path is a 404', () async {
      await expectLater(WebSocket.connect(viaUrl('NOT-AN-ID')), throwsA(isA<WebSocketException>()));
    });

    test('local-network check', () {
      for (final ok in ['10.1.2.3', '172.16.0.1', '172.31.255.255', '192.168.1.9', '127.0.0.1', '169.254.3.4', '::1', 'fe80::1', 'fd12::5']) {
        expect(isLocalNetworkHost(ok), isTrue, reason: ok);
      }
      for (final no in ['8.8.8.8', '172.32.0.1', '100.64.0.1', '203.0.113.5', '2001:db8::1', 'example.org', '']) {
        expect(isLocalNetworkHost(no), isFalse, reason: no);
      }
    });
  });

  group('end to end through a real target', () {
    late SignalingListener targetListener;
    late FakeConnectivity targetNet;
    late Dialer dialer;

    setUp(() async {
      targetNet = FakeConnectivity(addresses: ['192.168.1.20:47100']);
      targetListener = SignalingListener(
        identity: target,
        connectivity: targetNet,
        localInfo: () => _info('Office PC'),
        admit: (peer, want) => null,
      );
      expect(await targetListener.start(port: 0, address: InternetAddress.loopbackIPv4), isTrue);
      lookupResult = _peer(target, targetListener.port);
      dialer = Dialer(
        identity: viewer,
        localInfo: () => _info('Home Mac'),
        advertisedAddresses: () => const [],
        stagger: const Duration(milliseconds: 50),
        gatewayDelay: const Duration(milliseconds: 100),
      );
    });

    tearDown(() => targetListener.dispose());

    NetAddress gatewayRoute({String? forId}) =>
        NetAddress('127.0.0.1', gateListener.port, viaId: forId ?? target.id);

    test('the viewer performs the signed handshake with the target and gets the gateway\'s TURN', () async {
      final incomingFuture = targetListener.incoming.first;
      final result = await dialer.dial(
        addresses: [gatewayRoute()],
        want: HelloWant.control,
        expectedId: target.id,
      );
      final incoming = await incomingFuture;
      expect(result.peer.id, target.id, reason: 'the target\'s own key, verified by the viewer');
      expect(result.peer.name, 'Office PC');
      expect(result.connectedTo.isViaGateway, isTrue);
      expect(incoming.peer.id, viewer.id);
      expect(incoming.dialed, '127.0.0.1:${gateListener.port}', reason: 'the gateway address the viewer dialed');
      // The target issued its own grant; the viewer got the gateway's.
      expect(targetNet.issued, hasLength(1));
      expect(result.turn!.username, startsWith('user'));
      expect(result.turn!.udpPort, 47200);
      expect(gwNet.gatewayGrants, [true]);
      result.channel.dispose();
      incoming.channel.dispose();
    });

    test('an ID that is not the one expected is an identity mismatch, even through the gateway', () async {
      final stranger = await _identity(9);
      await expectLater(
        dialer.dial(
          addresses: [gatewayRoute(forId: stranger.id)],
          want: HelloWant.control,
          expectedId: stranger.id,
        ),
        throwsA(isA<DialException>()
            .having((e) => e.kind, 'kind', DialFailure.identityMismatch)
            .having((e) => e.actualId, 'actualId', target.id)),
      );
    });

    test('no trust on first use through a gateway: routes without a verifiable ID are dropped', () async {
      await expectLater(
        dialer.dial(addresses: [gatewayRoute()], want: HelloWant.control),
        throwsA(isA<DialException>().having((e) => e.kind, 'kind', DialFailure.unreachable)),
      );
      await expectLater(
        dialer.probe([gatewayRoute()]),
        throwsA(isA<DialException>().having((e) => e.kind, 'kind', DialFailure.unreachable)),
      );
      // A route meant for another device is not used either.
      final other = await _identity(5);
      await expectLater(
        dialer.dial(addresses: [gatewayRoute(forId: other.id)], want: HelloWant.control, expectedId: target.id),
        throwsA(isA<DialException>().having((e) => e.kind, 'kind', DialFailure.unreachable)),
      );
      expect(lookups, isEmpty);
    });

    test('a gateway that cannot find the device fails the dial as unreachable', () async {
      lookupResult = null;
      await expectLater(
        dialer.dial(addresses: [gatewayRoute()], want: HelloWant.control, expectedId: target.id),
        throwsA(isA<DialException>().having((e) => e.kind, 'kind', DialFailure.unreachable)),
      );
    });

    test('direct addresses win: the gateway route never starts when the device answers directly', () async {
      // A long head start, so a slow machine cannot make the gateway attempt begin first.
      final patient = Dialer(
        identity: viewer,
        localInfo: () => _info('Home Mac'),
        advertisedAddresses: () => const [],
        gatewayDelay: const Duration(seconds: 3),
      );
      final direct = NetAddress('127.0.0.1', targetListener.port);
      final result = await patient.dial(
        addresses: [gatewayRoute(), direct],
        want: HelloWant.control,
        expectedId: target.id,
      );
      expect(result.connectedTo, direct);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(lookups, isEmpty);
      result.channel.dispose();
    });

    test('when the direct address black-holes, the gateway route takes over', () async {
      // Accepts TCP and then says nothing: the direct attempt hangs.
      final hole = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(hole.close);
      hole.listen((s) => s.listen((_) {}));
      final result = await dialer.dial(
        addresses: [NetAddress('127.0.0.1', hole.port), gatewayRoute()],
        want: HelloWant.control,
        expectedId: target.id,
      );
      expect(result.connectedTo.isViaGateway, isTrue);
      expect(result.peer.id, target.id);
      result.channel.dispose();
    });

    test('a dropped signaling connection resumes through the same gateway route', () async {
      final incomingFuture = targetListener.incoming.first;
      final result = await dialer.dial(addresses: [gatewayRoute()], want: HelloWant.control, expectedId: target.id);
      final incoming = await incomingFuture;
      final events = <Object>[];
      incoming.channel.events.listen(events.add);
      final resumed = result.channel.events.where((e) => e.runtimeType.toString() == 'SignalingResumed').first;
      result.channel.debugDropSocket();
      await resumed.timeout(const Duration(seconds: 15));
      expect(result.channel.isAttached, isTrue);
      result.channel.dispose();
      incoming.channel.dispose();
    });
  });

  group('race schedule', () {
    late Dialer d;
    setUp(() async {
      d = Dialer(
        identity: await _identity(1),
        localInfo: () => _info('x'),
        advertisedAddresses: () => const [],
      );
    });

    test('direct addresses are staggered, gateway routes start 500 ms later and are staggered too', () {
      const direct1 = NetAddress('10.0.0.1', 47100);
      const direct2 = NetAddress('10.0.0.2', 47100);
      const v6 = NetAddress('2001:db8::1', 47100);
      const gw1 = NetAddress('203.0.113.5', 47100, viaId: 'AAAAAAAAAAAAAAAA');
      const gw2 = NetAddress('203.0.113.6', 47100, viaId: 'AAAAAAAAAAAAAAAA');
      expect(
        d.raceSchedule([direct1, gw1, direct2, gw2, v6]),
        const [
          Duration.zero,
          Duration(milliseconds: 500),
          Duration(milliseconds: 250),
          Duration(milliseconds: 750),
          Duration(milliseconds: 500),
        ],
      );
    });

    test('with nothing direct to wait for, a gateway route starts at once', () {
      const gw1 = NetAddress('203.0.113.5', 47100, viaId: 'AAAAAAAAAAAAAAAA');
      expect(d.raceSchedule([gw1]), const [Duration.zero]);
    });
  });

  group('addresses', () {
    test('a via route is a different address from the direct one, with its own path', () {
      const a = NetAddress('203.0.113.5', 47100);
      final via = a.viaTarget('K7M2P9XQ4TAB8HDE');
      expect(via == a, isFalse);
      expect(a.signalingUri.path, '/thelxis');
      expect(via.signalingUri.path, '/thelxis/via/K7M2P9XQ4TAB8HDE');
      expect(via.hostPort, '203.0.113.5:47100', reason: 'dialed and the TURN host are the gateway');
      expect(via.isViaGateway, isTrue);
    });
  });
}

Future<void> _until(bool Function() cond, {Duration timeout = const Duration(seconds: 8)}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
