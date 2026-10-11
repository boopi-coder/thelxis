import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/net/connectivity/stun_message.dart';
import 'package:thelxis/net/connectivity/turn_grants.dart';
import 'package:thelxis/net/connectivity/turn_server.dart';

import 'turn_test_client.dart';

class _Harness {
  _Harness({
    this.localPeers = const {'127.0.0.1'},
    Clock? clock,
    int maxPerGrant = 4,
  }) : clock = clock ?? DateTime.now,
       grants = TurnGrantStore(clock: clock) {
    server = TurnServer(
      grants: grants,
      udpPort: 0,
      tcpPort: 0,
      relayAddress: () => InternetAddress.loopbackIPv4,
      isLocalPeer: (a) async => localPeers.contains(a.address),
      maxAllocationsPerGrant: maxPerGrant,
      clock: clock,
    );
  }

  final Set<String> localPeers;
  final Clock clock;
  final TurnGrantStore grants;
  late final TurnServer server;
  final List<TurnTestClient> clients = [];
  final List<RawDatagramSocket> sockets = [];

  Future<void> start() async {
    final result = await server.start();
    expect(result.udp, isTrue);
    expect(result.tcp, isTrue);
  }

  Future<TurnTestClient> udp() async {
    final c = await TurnTestClient.udp(server.boundUdpPort!);
    clients.add(c);
    return c;
  }

  Future<TurnTestClient> tcp() async {
    final c = await TurnTestClient.tcp(server.boundTcpPort!);
    clients.add(c);
    return c;
  }

  /// UDP echo peer on 127.0.0.1.
  Future<RawDatagramSocket> echo() async {
    final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    s.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = s.receive();
      if (d != null) s.send(d.data, d.address, d.port);
    });
    sockets.add(s);
    return s;
  }

  Future<void> dispose() async {
    for (final c in clients) {
      c.close();
    }
    for (final s in sockets) {
      s.close();
    }
    await server.stop();
  }
}

void main() {
  late _Harness h;

  tearDown(() async => h.dispose());

  group('STUN binding', () {
    test('answers with the reflexive address, no auth needed', () async {
      h = _Harness();
      await h.start();
      final c = await h.udp();
      final response = await c.call(
        StunMessage(
          method: StunMethod.binding,
          messageClass: StunClass.request,
          transactionId: randomTransactionId(),
        ),
      );
      expect(response.messageClass, StunClass.success);
      final mapped = response.xorAddress(StunAttr.xorMappedAddress)!;
      expect(mapped.address.address, '127.0.0.1');
      expect(mapped.port, c.localPort);
      expect(response.verifyFingerprint(), isTrue);
    });

    test('ignores garbage datagrams and bad fingerprints', () async {
      h = _Harness();
      await h.start();
      final c = await h.udp();
      c.sendRaw(Uint8List.fromList([1, 2, 3]));
      final tampered = StunMessage(
        method: StunMethod.binding,
        messageClass: StunClass.request,
        transactionId: randomTransactionId(),
      ).encode(fingerprint: true)..[19] ^= 0xff;
      c.sendRaw(tampered);
      expect(
        await c.nextPacket(timeout: const Duration(milliseconds: 300)),
        isNull,
      );
    });
  });

  group('authentication', () {
    test(
      'Allocate without credentials gets 401 with realm and nonce',
      () async {
        h = _Harness();
        await h.start();
        final c = await h.udp();
        final r = await c.call(
          StunMessage(
            method: StunMethod.allocate,
            messageClass: StunClass.request,
            transactionId: randomTransactionId(),
            attributes: [transportUdp()],
          ),
        );
        expect(r.messageClass, StunClass.error);
        expect(r.errorCode!.code, 401);
        expect(r.stringAttribute(StunAttr.realm), 'thelxis');
        expect(r.stringAttribute(StunAttr.nonce), isNotEmpty);
        expect(r.hasIntegrity, isFalse);
      },
    );

    test('wrong password and unknown user are rejected', () async {
      h = _Harness();
      await h.start();
      final grant = h.grants.issue(ttl: const Duration(hours: 1));
      final wrong = await h.udp();
      var r = await wrong.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        'not-it',
      );
      expect(r.errorCode!.code, 401);
      final unknown = await h.udp();
      r = await unknown.authed(
        StunMethod.allocate,
        [transportUdp()],
        'nobody',
        grant.password,
      );
      expect(r.errorCode!.code, 401);
      expect(h.server.allocationCount, 0);
    });

    test('stale nonce yields 438 and the retry succeeds', () async {
      var now = DateTime.utc(2030);
      h = _Harness(clock: () => now);
      await h.start();
      final grant = h.grants.issue(ttl: const Duration(hours: 4));
      final c = await h.udp();
      var r = await c.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.password,
      );
      expect(r.messageClass, StunClass.success);
      now = now.add(const Duration(minutes: 11));
      r = await c.authed(
        StunMethod.refresh,
        [],
        grant.username,
        grant.password,
      );
      expect(r.errorCode!.code, 438);
      r = await c.authed(
        StunMethod.refresh,
        [],
        grant.username,
        grant.password,
      );
      expect(r.messageClass, StunClass.success);
    });

    test('revoked grant: valid for 60 s, then credentials die', () async {
      var now = DateTime.utc(2030);
      h = _Harness(clock: () => now);
      await h.start();
      final grant = h.grants.issue(ttl: const Duration(hours: 12));
      final first = await h.udp();
      var r = await first.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.password,
      );
      expect(r.messageClass, StunClass.success);

      h.grants.revoke(grant.username);
      now = now.add(const Duration(seconds: 30));
      final within = await h.udp();
      r = await within.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.password,
      );
      expect(r.messageClass, StunClass.success, reason: 'grace period');

      now = now.add(const Duration(seconds: 31));
      final after = await h.udp();
      r = await after.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.password,
      );
      expect(r.errorCode!.code, 401);
      expect(h.server.allocationCount, 2);
      h.server.sweepNow();
      expect(
        h.server.allocationCount,
        0,
        reason: 'allocations of a dead grant are torn down',
      );
    });

    test('expired TTL kills the grant', () async {
      var now = DateTime.utc(2030);
      h = _Harness(clock: () => now);
      await h.start();
      final grant = h.grants.issue(ttl: const Duration(minutes: 5));
      now = now.add(const Duration(minutes: 6));
      final c = await h.udp();
      final r = await c.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.password,
      );
      expect(r.errorCode!.code, 401);
    });
  });

  group('Allocate / Refresh', () {
    test('success carries relayed address, lifetime and integrity', () async {
      h = _Harness();
      await h.start();
      final grant = h.grants.issue(ttl: const Duration(hours: 1));
      final c = await h.udp();
      final r = await c.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.password,
      );
      expect(r.messageClass, StunClass.success);
      expect(r.verifyIntegrity(c.key!), isTrue);
      final relayed = r.xorAddress(StunAttr.xorRelayedAddress)!;
      expect(relayed.address.address, '127.0.0.1');
      expect(relayed.port, greaterThan(0));
      expect(r.uint32Attribute(StunAttr.lifetime), inInclusiveRange(599, 600));
      final mapped = r.xorAddress(StunAttr.xorMappedAddress)!;
      expect(mapped.port, c.localPort);
    });

    test('lifetime is capped at one hour', () async {
      h = _Harness();
      await h.start();
      final grant = h.grants.issue(ttl: const Duration(hours: 1));
      final c = await h.udp();
      final r = await c.authed(
        StunMethod.allocate,
        [transportUdp(), StunAttribute.uint32(StunAttr.lifetime, 86400)],
        grant.username,
        grant.password,
      );
      expect(
        r.uint32Attribute(StunAttr.lifetime),
        inInclusiveRange(3599, 3600),
      );
    });

    test('a short requested lifetime is raised to the 600 s default', () async {
      h = _Harness();
      await h.start();
      final grant = h.grants.issue(ttl: const Duration(hours: 1));
      final c = await h.udp();
      final r = await c.authed(
        StunMethod.allocate,
        [transportUdp(), StunAttribute.uint32(StunAttr.lifetime, 30)],
        grant.username,
        grant.password,
      );
      expect(r.uint32Attribute(StunAttr.lifetime), inInclusiveRange(599, 600));
    });

    test('only UDP relay is offered', () async {
      h = _Harness();
      await h.start();
      final grant = h.grants.issue(ttl: const Duration(hours: 1));
      final c = await h.udp();
      final r = await c.authed(
        StunMethod.allocate,
        [
          StunAttribute(
            StunAttr.requestedTransport,
            Uint8List.fromList([6, 0, 0, 0]),
          ),
        ],
        grant.username,
        grant.password,
      );
      expect(r.errorCode!.code, 442);
    });

    test('at most four allocations per grant', () async {
      h = _Harness();
      await h.start();
      final grant = h.grants.issue(ttl: const Duration(hours: 1));
      for (var i = 0; i < 4; i++) {
        final c = await h.udp();
        final r = await c.authed(
          StunMethod.allocate,
          [transportUdp()],
          grant.username,
          grant.password,
        );
        expect(r.messageClass, StunClass.success, reason: 'allocation $i');
      }
      final fifth = await h.udp();
      final r = await fifth.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.password,
      );
      expect(r.errorCode!.code, 486);

      // A different grant is not affected by the first one's quota.
      final other = h.grants.issue(ttl: const Duration(hours: 1));
      final c = await h.udp();
      final ok = await c.authed(
        StunMethod.allocate,
        [transportUdp()],
        other.username,
        other.password,
      );
      expect(ok.messageClass, StunClass.success);
    });

    test('a second Allocate on the same 5-tuple is a mismatch, a retransmit is answered again', () async {
      h = _Harness();
      await h.start();
      final grant = h.grants.issue(ttl: const Duration(hours: 1));
      final c = await h.udp();
      final first = await c.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.password,
      );
      expect(first.messageClass, StunClass.success);
      final second = await c.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.password,
      );
      expect(second.errorCode!.code, 437);

      // Retransmission: same transaction id as the first request.
      final tid = randomTransactionId();
      StunMessage build() => StunMessage(
        method: StunMethod.allocate,
        messageClass: StunClass.request,
        transactionId: tid,
        attributes: [
          transportUdp(),
          StunAttribute.string(StunAttr.username, grant.username),
          StunAttribute.string(StunAttr.realm, c.realm!),
          StunAttribute.string(StunAttr.nonce, c.nonce!),
        ],
      );
      final other = await h.udp();
      other.realm = c.realm;
      other.nonce = c.nonce;
      final a = await other.call(build(), integrityKey: c.key);
      final b = await other.call(build(), integrityKey: c.key);
      expect(a.messageClass, StunClass.success);
      expect(b.messageClass, StunClass.success);
      expect(
        b.xorAddress(StunAttr.xorRelayedAddress)!.port,
        a.xorAddress(StunAttr.xorRelayedAddress)!.port,
      );
      expect(h.server.allocationCount, 2);
    });

    test('Refresh with lifetime 0 deletes the allocation', () async {
      h = _Harness();
      await h.start();
      final grant = h.grants.issue(ttl: const Duration(hours: 1));
      final c = await h.udp();
      await c.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.password,
      );
      expect(h.server.allocationCount, 1);
      final r = await c.authed(
        StunMethod.refresh,
        [StunAttribute.uint32(StunAttr.lifetime, 0)],
        grant.username,
        grant.password,
      );
      expect(r.messageClass, StunClass.success);
      expect(r.uint32Attribute(StunAttr.lifetime), 0);
      expect(h.server.allocationCount, 0);
      final perm = await c.authed(
        StunMethod.createPermission,
        [peerAttr('127.0.0.1', 9)],
        grant.username,
        grant.password,
      );
      expect(perm.errorCode!.code, 437);
    });

    test('Refresh extends the lifetime', () async {
      h = _Harness();
      await h.start();
      final grant = h.grants.issue(ttl: const Duration(hours: 1));
      final c = await h.udp();
      await c.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.password,
      );
      final r = await c.authed(
        StunMethod.refresh,
        [StunAttribute.uint32(StunAttr.lifetime, 1800)],
        grant.username,
        grant.password,
      );
      expect(r.uint32Attribute(StunAttr.lifetime), 1800);
    });
  });

  group('relay end to end', () {
    test('ChannelBind + ChannelData echo over UDP', () async {
      h = _Harness();
      await h.start();
      final echo = await h.echo();
      final grant = h.grants.issue(ttl: const Duration(hours: 1));
      final c = await h.udp();

      final alloc = await c.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.password,
      );
      expect(alloc.messageClass, StunClass.success);

      final perm = await c.authed(
        StunMethod.createPermission,
        [peerAttr('127.0.0.1', echo.port)],
        grant.username,
        grant.password,
      );
      expect(perm.messageClass, StunClass.success);
      expect(perm.verifyIntegrity(c.key!), isTrue);

      final bind = await c.authed(
        StunMethod.channelBind,
        [channelNumberAttr(0x4000), peerAttr('127.0.0.1', echo.port)],
        grant.username,
        grant.password,
      );
      expect(bind.messageClass, StunClass.success);

      final payload = Uint8List.fromList(utf8.encode('dtls-ish packet 1234'));
      c.sendRaw(ChannelData.encode(0x4000, payload));
      final back = await c.nextPacket();
      expect(back, isNotNull);
      final frame = ChannelData.parse(back!)!;
      expect(frame.channel, 0x4000);
      expect(frame.payload, payload);
    });

    test('Send / Data indications work without a channel', () async {
      h = _Harness();
      await h.start();
      final echo = await h.echo();
      final grant = h.grants.issue(ttl: const Duration(hours: 1));
      final c = await h.udp();
      await c.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.password,
      );
      await c.authed(
        StunMethod.createPermission,
        [peerAttr('127.0.0.1', echo.port)],
        grant.username,
        grant.password,
      );

      final tid = randomTransactionId();
      final payload = Uint8List.fromList([9, 8, 7, 6, 5]);
      c.sendRaw(
        StunMessage(
          method: StunMethod.send,
          messageClass: StunClass.indication,
          transactionId: tid,
          attributes: [
            StunAttribute.xorAddress(
              StunAttr.xorPeerAddress,
              InternetAddress.loopbackIPv4,
              echo.port,
              tid,
            ),
            StunAttribute(StunAttr.data, payload),
          ],
        ).encode(),
      );
      final back = await c.nextPacket();
      final indication = StunMessage.parse(back!)!;
      expect(indication.method, StunMethod.data);
      expect(indication.messageClass, StunClass.indication);
      final from = indication.xorAddress(StunAttr.xorPeerAddress)!;
      expect(from.port, echo.port);
      expect(indication.attribute(StunAttr.data)!.value, payload);
    });

    test('inbound traffic from a peer without permission is dropped', () async {
      h = _Harness();
      await h.start();
      final grant = h.grants.issue(ttl: const Duration(hours: 1));
      final c = await h.udp();
      final alloc = await c.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.password,
      );
      final relayedPort = alloc.xorAddress(StunAttr.xorRelayedAddress)!.port;
      final stranger = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      h.sockets.add(stranger);
      stranger.send([1, 2, 3], InternetAddress.loopbackIPv4, relayedPort);
      expect(
        await c.nextPacket(timeout: const Duration(milliseconds: 300)),
        isNull,
      );
    });

    test('Send indication without permission is dropped', () async {
      h = _Harness();
      await h.start();
      var received = 0;
      final sink = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      sink.listen((e) {
        if (e == RawSocketEvent.read && sink.receive() != null) received++;
      });
      h.sockets.add(sink);
      final grant = h.grants.issue(ttl: const Duration(hours: 1));
      final c = await h.udp();
      await c.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.password,
      );
      final tid = randomTransactionId();
      c.sendRaw(
        StunMessage(
          method: StunMethod.send,
          messageClass: StunClass.indication,
          transactionId: tid,
          attributes: [
            StunAttribute.xorAddress(
              StunAttr.xorPeerAddress,
              InternetAddress.loopbackIPv4,
              sink.port,
              tid,
            ),
            StunAttribute(StunAttr.data, Uint8List.fromList([1])),
          ],
        ).encode(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(received, 0);
    });

    test('TCP transport: framing, padding and ChannelData echo', () async {
      h = _Harness();
      await h.start();
      final echo = await h.echo();
      final grant = h.grants.issue(ttl: const Duration(hours: 1));
      final c = await h.tcp();
      final alloc = await c.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.password,
      );
      expect(alloc.messageClass, StunClass.success);
      await c.authed(
        StunMethod.createPermission,
        [peerAttr('127.0.0.1', echo.port)],
        grant.username,
        grant.password,
      );
      final bind = await c.authed(
        StunMethod.channelBind,
        [channelNumberAttr(0x4001), peerAttr('127.0.0.1', echo.port)],
        grant.username,
        grant.password,
      );
      expect(bind.messageClass, StunClass.success);

      // Two frames in a single TCP write; 5-byte payload needs 3 pad bytes.
      final p1 = Uint8List.fromList([1, 2, 3, 4, 5]);
      final p2 = Uint8List.fromList([10, 20, 30, 40]);
      c.sendRaw(
        Uint8List.fromList([
          ...ChannelData.encode(0x4001, p1, pad: true),
          ...ChannelData.encode(0x4001, p2, pad: true),
        ]),
      );
      final got = <Uint8List>[];
      for (var i = 0; i < 2; i++) {
        final packet = await c.nextPacket();
        expect(packet, isNotNull);
        got.add(ChannelData.parse(packet!)!.payload);
      }
      got.sort((a, b) => a.length.compareTo(b.length));
      expect(got[0], p2);
      expect(got[1], p1);
    });

    test('TCP connection closing removes the allocation', () async {
      h = _Harness();
      await h.start();
      final grant = h.grants.issue(ttl: const Duration(hours: 1));
      final c = await h.tcp();
      await c.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.password,
      );
      expect(h.server.allocationCount, 1);
      c.close();
      for (var i = 0; i < 20 && h.server.allocationCount > 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(h.server.allocationCount, 0);
    });
  });

  group('never an open relay', () {
    test('CreatePermission for a non-local peer is 403', () async {
      h = _Harness();
      await h.start();
      final grant = h.grants.issue(ttl: const Duration(hours: 1));
      final c = await h.udp();
      await c.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.password,
      );
      final r = await c.authed(
        StunMethod.createPermission,
        [peerAttr('8.8.8.8', 53)],
        grant.username,
        grant.password,
      );
      expect(r.messageClass, StunClass.error);
      expect(r.errorCode!.code, 403);
      // One bad peer poisons the whole request: the local one is not installed either.
      final mixed = await c.authed(
        StunMethod.createPermission,
        [peerAttr('127.0.0.1', 5000), peerAttr('93.184.216.34', 80)],
        grant.username,
        grant.password,
      );
      expect(mixed.errorCode!.code, 403);
    });

    test(
      'ChannelBind for a non-local peer is 403 and nothing is relayed',
      () async {
        h = _Harness();
        await h.start();
        final grant = h.grants.issue(ttl: const Duration(hours: 1));
        final c = await h.udp();
        await c.authed(
          StunMethod.allocate,
          [transportUdp()],
          grant.username,
          grant.password,
        );
        final r = await c.authed(
          StunMethod.channelBind,
          [channelNumberAttr(0x4000), peerAttr('203.0.113.9', 4444)],
          grant.username,
          grant.password,
        );
        expect(r.errorCode!.code, 403);
        c.sendRaw(ChannelData.encode(0x4000, Uint8List.fromList([1, 2, 3])));
        expect(
          await c.nextPacket(timeout: const Duration(milliseconds: 300)),
          isNull,
        );
      },
    );

    test('IPv6 peers are refused (relay is IPv4 only)', () async {
      h = _Harness(localPeers: {'127.0.0.1', '::1'});
      await h.start();
      final grant = h.grants.issue(ttl: const Duration(hours: 1));
      final c = await h.udp();
      await c.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.password,
      );
      final r = await c.authed(
        StunMethod.createPermission,
        const [],
        grant.username,
        grant.password,
        attributesFor: (tid) => [
          StunAttribute.xorAddress(
            StunAttr.xorPeerAddress,
            InternetAddress('::1'),
            4000,
            tid,
          ),
        ],
      );
      expect(r.errorCode!.code, 443);
    });

    test('channel numbers outside 0x4000-0x7FFE are rejected', () async {
      h = _Harness();
      await h.start();
      final grant = h.grants.issue(ttl: const Duration(hours: 1));
      final c = await h.udp();
      await c.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.password,
      );
      final r = await c.authed(
        StunMethod.channelBind,
        [channelNumberAttr(0x3FFF), peerAttr('127.0.0.1', 5000)],
        grant.username,
        grant.password,
      );
      expect(r.errorCode!.code, 400);
    });

    test('a channel number cannot be rebound to a different peer', () async {
      h = _Harness();
      await h.start();
      final grant = h.grants.issue(ttl: const Duration(hours: 1));
      final c = await h.udp();
      await c.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.password,
      );
      var r = await c.authed(
        StunMethod.channelBind,
        [channelNumberAttr(0x4000), peerAttr('127.0.0.1', 5000)],
        grant.username,
        grant.password,
      );
      expect(r.messageClass, StunClass.success);
      r = await c.authed(
        StunMethod.channelBind,
        [channelNumberAttr(0x4000), peerAttr('127.0.0.1', 5001)],
        grant.username,
        grant.password,
      );
      expect(r.errorCode!.code, 400);
      r = await c.authed(
        StunMethod.channelBind,
        [channelNumberAttr(0x4001), peerAttr('127.0.0.1', 5000)],
        grant.username,
        grant.password,
      );
      expect(r.errorCode!.code, 400);
      // Refreshing the same binding is fine.
      r = await c.authed(
        StunMethod.channelBind,
        [channelNumberAttr(0x4000), peerAttr('127.0.0.1', 5000)],
        grant.username,
        grant.password,
      );
      expect(r.messageClass, StunClass.success);
    });
  });

  group('IPv6 UDP', () {
    Future<StunMessage?> bindingOver6(int port, InternetAddress to) async {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv6,
        0,
      );
      addTearDown(socket.close);
      final tid = randomTransactionId();
      final request = StunMessage(
        method: StunMethod.binding,
        messageClass: StunClass.request,
        transactionId: tid,
      ).encode(fingerprint: true);
      for (var i = 0; i < 5; i++) {
        socket.send(request, to, port);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final d = socket.receive();
        if (d != null) return StunMessage.parse(d.data);
      }
      return null;
    }

    Future<bool> ipv6Available() async {
      try {
        (await RawDatagramSocket.bind(InternetAddress.loopbackIPv6, 0)).close();
        return true;
      } on SocketException {
        return false;
      }
    }

    test('binds per concrete address and follows address changes', () async {
      if (!await ipv6Available()) {
        markTestSkipped('no IPv6 loopback on this machine');
        return;
      }
      h = _Harness();
      await h.start();
      final port = h.server.boundUdpPort!;

      // A wildcard :: bind would collide with the IPv4 socket on Linux and
      // macOS; a concrete address must not.
      await h.server.setUdpIpv6Addresses([InternetAddress.loopbackIPv6]);
      final reply = await bindingOver6(port, InternetAddress.loopbackIPv6);
      expect(reply, isNotNull);
      expect(reply!.messageClass, StunClass.success);
      expect(
        reply.xorAddress(StunAttr.xorMappedAddress)!.address.address,
        '::1',
      );

      // IPv4 keeps working next to it.
      final c = await h.udp();
      final v4 = await c.call(
        StunMessage(
          method: StunMethod.binding,
          messageClass: StunClass.request,
          transactionId: randomTransactionId(),
        ),
      );
      expect(v4.messageClass, StunClass.success);

      // Address gone: the socket is closed and nobody answers any more.
      await h.server.setUdpIpv6Addresses(const []);
      expect(await bindingOver6(port, InternetAddress.loopbackIPv6), isNull);
    });

    test('an address that cannot be bound is tolerated', () async {
      h = _Harness();
      await h.start();
      await h.server.setUdpIpv6Addresses([
        InternetAddress('2a02:abcd:ffff::1'),
      ]);
      expect(h.server.isRunning, isTrue);
    });
  });

  group('lifecycle', () {
    test('reports a busy port and keeps going', () async {
      final blocker = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: false,
      );
      final tcpBlocker = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      final grants = TurnGrantStore();
      final server = TurnServer(
        grants: grants,
        udpPort: blocker.port,
        tcpPort: tcpBlocker.port,
        relayAddress: () => InternetAddress.loopbackIPv4,
        isLocalPeer: (_) async => true,
      );
      final result = await server.start();
      expect(result.udp, isFalse);
      expect(result.tcp, isFalse);
      expect(result.errors, hasLength(2));
      expect(result.errors.first, contains('in use'));
      expect(server.isRunning, isFalse);
      await server.stop();
      blocker.close();
      await tcpBlocker.close();
    });

    test('stop frees the ports and tears down allocations', () async {
      h = _Harness();
      await h.start();
      final grant = h.grants.issue(ttl: const Duration(hours: 1));
      final c = await h.udp();
      await c.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.password,
      );
      final udpPort = h.server.boundUdpPort!;
      await h.server.stop();
      expect(h.server.allocationCount, 0);
      final again = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        udpPort,
        reuseAddress: false,
      );
      again.close();
    });
  });
}
