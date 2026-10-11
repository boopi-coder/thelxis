import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/net/connectivity/connectivity.dart';
import 'package:thelxis/net/connectivity/connectivity_impl.dart';
import 'package:thelxis/net/connectivity/interfaces.dart';
import 'package:thelxis/net/connectivity/port_mapper.dart';
import 'package:thelxis/net/connectivity/stun_message.dart';

import 'fake_mapping.dart';
import 'turn_test_client.dart';

const _fastConfig = ConnectivityConfig(
  turnUdpPort: 0,
  turnTcpPort: 0,
  networkWatchInterval: Duration(hours: 1),
  minRenewalDelay: Duration(milliseconds: 40),
  retryDelay: Duration(hours: 1),
);

List<LocalInterface> _home() => [
  LocalInterface('en0', [
    InternetAddress('192.168.1.50'),
    InternetAddress('2a02:abcd:1::50'),
    InternetAddress('fe80::1'),
  ]),
  LocalInterface('docker0', [InternetAddress('172.17.0.1')]),
];

void main() {
  late ConnectivityService service;
  late FakeRouter router;
  late CountingProbe probe;
  var interfaces = _home();
  var now = DateTime.utc(2030);

  ConnectivityService build({
    List<LocalInterface> Function()? lister,
    ConnectivityConfig config = _fastConfig,
    List<MappingProbe>? probes,
  }) => ConnectivityService(
    config: config,
    interfaceLister: () async => (lister ?? () => interfaces)(),
    mapper: PortMapper(probes: probes ?? [probe.probe]),
    clock: () => now,
  );

  setUp(() {
    interfaces = _home();
    now = DateTime.utc(2030);
    router = FakeRouter(MappingMethod.upnp);
    probe = CountingProbe(MappingMethod.upnp, router: router);
    service = build();
  });

  tearDown(() async => service.stop());

  group('without port mapping', () {
    test('reports addresses and runs TURN', () async {
      await service.start(portMapping: false);
      final r = service.report.value;
      expect(r.lanIPv4, ['192.168.1.50']);
      expect(r.globalIPv6, ['2a02:abcd:1::50']);
      expect(r.turnRunning, isTrue);
      expect(r.gatewayFound, isFalse);
      expect(r.mappings, isEmpty);
      expect(r.problems, isEmpty);
      expect(r.reachableIPv6, isTrue);
      expect(r.reachableIPv4, isFalse);
      expect(probe.calls, 0, reason: 'router must not be touched');
    });

    test('advertised addresses: IPv6 (bracketed) before LAN', () async {
      await service.start(portMapping: false);
      expect(service.advertisedAddresses(), [
        '[2a02:abcd:1::50]:47100',
        '192.168.1.50:47100',
      ]);
    });

    test('nothing is advertised before start and after stop', () async {
      expect(service.advertisedAddresses(), isEmpty);
      await service.start(portMapping: false);
      await service.stop();
      expect(service.advertisedAddresses(), isEmpty);
      expect(service.report.value.turnRunning, isFalse);
      expect(service.report.value.lanIPv4, isEmpty);
    });
  });

  group('with port mapping', () {
    test('public external address: mapped and advertised first', () async {
      router.portShift = 5;
      await service.start(portMapping: true);
      final r = service.report.value;
      expect(r.gatewayFound, isTrue);
      expect(r.mappingMethod, MappingMethod.upnp);
      expect(r.externalIPv4, '93.184.216.34');
      expect(r.externalIsPublic, isTrue);
      expect(r.cgnat, isFalse);
      expect(r.problems, isEmpty);
      expect(
        r.mappings
            .where((m) => m.protocol == MappingProtocol.tcp)
            .first
            .externalPort,
        47105,
      );
      expect(r.reachableIPv4, isTrue);
      expect(service.advertisedAddresses(), [
        '93.184.216.34:47105',
        '[2a02:abcd:1::50]:47100',
        '192.168.1.50:47100',
      ]);
    });

    test(
      'maps signaling TCP, TURN UDP and TURN TCP (actual bound ports)',
      () async {
        await service.start(portMapping: true);
        final keys = router.mapCalls.toSet();
        expect(keys, contains('tcp:47100'));
        expect(keys.where((k) => k.startsWith('udp:')), hasLength(1));
        expect(keys.where((k) => k.startsWith('tcp:')), hasLength(2));
        expect(service.report.value.mappings, hasLength(3));
      },
    );

    test('carrier-grade NAT is detected and not advertised', () async {
      router.external = '100.72.5.6';
      await service.start(portMapping: true);
      final r = service.report.value;
      expect(r.externalIPv4, '100.72.5.6');
      expect(r.externalIsPublic, isFalse);
      expect(r.cgnat, isTrue);
      expect(r.reachableIPv4, isFalse);
      expect(r.problems.single, contains('carrier-grade NAT'));
      expect(r.problems.single, contains('100.72.5.6'));
      expect(
        service.advertisedAddresses(),
        isNot(contains(startsWith('100.72.5.6'))),
      );
    });

    test('a private WAN address means double NAT', () async {
      router.external = '192.168.0.2';
      await service.start(portMapping: true);
      final r = service.report.value;
      expect(r.cgnat, isTrue);
      expect(r.problems.single, contains('double NAT'));
    });

    test('no router found', () async {
      probe.router = null;
      await service.start(portMapping: true);
      final r = service.report.value;
      expect(r.gatewayFound, isFalse);
      expect(r.mappings, isEmpty);
      expect(r.problems, contains('No UPnP/NAT-PMP/PCP router found'));
      expect(service.advertisedAddresses(), [
        '[2a02:abcd:1::50]:47100',
        '192.168.1.50:47100',
      ]);
      expect(r.turnRunning, isTrue, reason: 'TURN works without a router');
    });

    test('router found but refusing: unverified external address is offered after IPv6', () async {
      router.refuse.add('tcp:47100');
      await service.start(portMapping: true);
      final r = service.report.value;
      expect(r.gatewayFound, isTrue);
      expect(r.mappings, isEmpty);
      expect(r.externalIPv4, '93.184.216.34');
      expect(r.problems.single, contains('UPnP could not map TCP 47100'));
      expect(service.advertisedAddresses(), [
        '[2a02:abcd:1::50]:47100',
        '93.184.216.34:47100',
        '192.168.1.50:47100',
      ]);
    });

    test('start is idempotent and does not remap', () async {
      await service.start(portMapping: true);
      final calls = probe.calls;
      await service.start(portMapping: true);
      expect(probe.calls, calls);
    });

    test('turning port mapping off removes the mappings', () async {
      await service.start(portMapping: true);
      await service.start(portMapping: false);
      expect(router.unmapCalls, hasLength(3));
      final r = service.report.value;
      expect(r.mappings, isEmpty);
      expect(r.externalIPv4, isNull);
      expect(r.turnRunning, isTrue);
    });

    test('stop removes mappings and stops TURN', () async {
      await service.start(portMapping: true);
      await service.stop();
      expect(router.unmapCalls, hasLength(3));
      expect(service.report.value.mappings, isEmpty);
      expect(service.report.value.turnRunning, isFalse);
    });

    test('a directly public interface address counts as external', () async {
      interfaces = [
        LocalInterface('eth0', [
          InternetAddress('198.19.1.1'),
          InternetAddress('8.8.4.4'),
        ]),
      ];
      probe.router = null;
      await service.start(portMapping: true);
      final r = service.report.value;
      expect(r.externalIPv4, '8.8.4.4');
      expect(r.externalIsPublic, isTrue);
      expect(
        r.problems,
        isEmpty,
        reason: 'no router needed when the NIC is public',
      );
      expect(service.advertisedAddresses().first, '8.8.4.4:47100');
    });

    test(
      'refresh re-scans interfaces and re-establishes the mapping',
      () async {
        await service.start(portMapping: true);
        expect(probe.calls, 1);
        interfaces = [
          LocalInterface('en0', [InternetAddress('10.0.0.7')]),
        ];
        router.external = '100.64.9.9';
        await service.refresh();
        final r = service.report.value;
        expect(probe.calls, 2);
        expect(r.lanIPv4, ['10.0.0.7']);
        expect(r.globalIPv6, isEmpty);
        expect(r.cgnat, isTrue);
      },
    );

    test(
      'moving to another router abandons old mappings without deleting them',
      () async {
        await service.start(portMapping: true);
        final other = FakeRouter(MappingMethod.natPmp, id: 'router-2');
        probe.router = other;
        await service.refresh();
        expect(router.unmapCalls, isEmpty);
        expect(router.closed, isTrue);
        expect(service.report.value.mappingMethod, MappingMethod.natPmp);
      },
    );

    test('lease renewal runs at half the lifetime', () async {
      router.lifetime = const Duration(milliseconds: 100);
      await service.start(portMapping: true);
      final initial = router.mapCalls.length;
      for (var i = 0; i < 60 && router.mapCalls.length <= initial; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(
        router.mapCalls.length,
        greaterThan(initial),
        reason: 'renewal re-requests the mappings',
      );
      expect(probe.calls, 1, reason: 'a healthy renewal does not rediscover');
    });

    test('failed renewal triggers rediscovery', () async {
      router.lifetime = const Duration(milliseconds: 100);
      await service.start(portMapping: true);
      router.failMaps = true;
      final replacement = FakeRouter(MappingMethod.upnp, id: 'router-1');
      probe.router = replacement;
      for (var i = 0; i < 60 && replacement.mapCalls.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(probe.calls, greaterThan(1));
      expect(
        replacement.mapCalls,
        isNotEmpty,
        reason: 'mappings were re-created on the rediscovered router',
      );
    });

    test(
      'permanent leases are only re-verified half-hourly (no tight loop)',
      () async {
        router.lifetime = Duration.zero;
        await service.start(portMapping: true);
        final initial = router.mapCalls.length;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(router.mapCalls.length, initial);
      },
    );
  });

  group('network changes', () {
    test(
      'a changed IPv4 set is noticed without refresh() and remaps',
      () async {
        final watching = build(
          config: const ConnectivityConfig(
            turnUdpPort: 0,
            turnTcpPort: 0,
            networkWatchInterval: Duration(milliseconds: 60),
            minRenewalDelay: Duration(hours: 1),
            retryDelay: Duration(hours: 1),
          ),
        );
        await watching.start(portMapping: true);
        expect(probe.calls, 1);
        interfaces = [
          LocalInterface('en0', [InternetAddress('172.20.0.9')]),
        ];
        router.external = '100.70.0.1';
        for (var i = 0; i < 40 && probe.calls < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(probe.calls, 2);
        expect(watching.report.value.lanIPv4, ['172.20.0.9']);
        expect(watching.report.value.cgnat, isTrue);
        await watching.stop();
      },
    );

    test(
      'an IPv6-only change updates the report but does not touch the router',
      () async {
        final watching = build(
          config: const ConnectivityConfig(
            turnUdpPort: 0,
            turnTcpPort: 0,
            networkWatchInterval: Duration(milliseconds: 60),
            minRenewalDelay: Duration(hours: 1),
            retryDelay: Duration(hours: 1),
          ),
        );
        await watching.start(portMapping: true);
        interfaces = [
          LocalInterface('en0', [
            InternetAddress('192.168.1.50'),
            InternetAddress('2a02:abcd:1::99'),
          ]),
        ];
        for (
          var i = 0;
          i < 40 && watching.report.value.globalIPv6.first != '2a02:abcd:1::99';
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(watching.report.value.globalIPv6, ['2a02:abcd:1::99']);
        expect(probe.calls, 1);
        await watching.stop();
      },
    );

    test('a TURN port that was busy is bound by the next start()', () async {
      final udp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: false,
      );
      final tcp = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      final late = build(
        config: ConnectivityConfig(
          turnUdpPort: udp.port,
          turnTcpPort: tcp.port,
          networkWatchInterval: const Duration(hours: 1),
        ),
      );
      await late.start(portMapping: false);
      expect(late.report.value.turnRunning, isFalse);
      udp.close();
      await tcp.close();
      await late.start(portMapping: false);
      expect(late.report.value.turnRunning, isTrue);
      expect(late.report.value.problems, isEmpty);
      await late.stop();
    });
  });

  group('report notifications', () {
    test('listening flag flows through and notifies', () async {
      var notified = 0;
      service.report.addListener(() => notified++);
      service.setListening(true);
      expect(service.report.value.listening, isTrue);
      service.setListening(true);
      expect(notified, 1);
      await service.start(portMapping: false);
      expect(service.report.value.listening, isTrue);
      service.setListening(false);
      expect(service.report.value.listening, isFalse);
    });

    test('mapping progress is published before the router answers', () async {
      final seen = <ReachabilityReport>[];
      service.report.addListener(() => seen.add(service.report.value));
      await service.start(portMapping: true);
      expect(seen.length, greaterThanOrEqualTo(2));
      expect(seen.first.mappings, isEmpty);
      expect(seen.first.turnRunning, isTrue);
      expect(seen.last.mappings, isNotEmpty);
    });

    test('no private IPv4 at all', () async {
      interfaces = [LocalInterface('lo1', const [])];
      await service.start(portMapping: true);
      final r = service.report.value;
      expect(r.problems, contains('No local IPv4 network found'));
      expect(r.problems, contains('No network connection'));
      expect(probe.calls, 0);
    });

    test('an interface enumeration failure is not fatal', () async {
      final broken = ConnectivityService(
        config: _fastConfig,
        interfaceLister: () async => throw const OSError('denied'),
        mapper: PortMapper(probes: [probe.probe]),
      );
      await broken.start(portMapping: true);
      expect(broken.report.value.lanIPv4, isEmpty);
      expect(broken.report.value.turnRunning, isTrue);
      await broken.stop();
    });
  });

  group('TURN grants', () {
    test('null while TURN is not running', () {
      expect(service.issueTurnGrant(), isNull);
    });

    test(
      'null when both TURN ports are taken, and the problem is reported',
      () async {
        final udp = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          0,
          reuseAddress: false,
        );
        final tcp = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
        final blocked = build(
          config: ConnectivityConfig(
            turnUdpPort: udp.port,
            turnTcpPort: tcp.port,
            networkWatchInterval: const Duration(hours: 1),
          ),
        );
        await blocked.start(portMapping: false);
        final r = blocked.report.value;
        expect(r.turnRunning, isFalse);
        expect(r.problems, hasLength(2));
        expect(r.problems.join(' '), contains('Port ${udp.port} (UDP) in use'));
        expect(r.problems.join(' '), contains('Port ${tcp.port} (TCP) in use'));
        expect(blocked.issueTurnGrant(), isNull);
        await blocked.stop();
        udp.close();
        await tcp.close();
      },
    );

    test('local ports unless the dialer used the external mapping', () async {
      router.portShift = 5;
      await service.start(portMapping: true);
      final r = service.report.value;
      final localUdp = r.mappings
          .firstWhere((m) => m.protocol == MappingProtocol.udp)
          .internalPort;
      final localTcp = r.mappings
          .where(
            (m) => m.protocol == MappingProtocol.tcp && m.internalPort != 47100,
          )
          .single
          .internalPort;

      for (final dialed in [
        null,
        '192.168.1.50:47100',
        '[2a02:abcd:1::50]:47100',
        '93.184.216.34:47100',
        'garbage',
      ]) {
        final g = service.issueTurnGrant(dialedAddress: dialed)!;
        expect(g.udpPort, localUdp, reason: '$dialed');
        expect(g.tcpPort, localTcp, reason: '$dialed');
      }

      final external = service.issueTurnGrant(
        dialedAddress: '93.184.216.34:47105',
      )!;
      expect(external.udpPort, localUdp + 5);
      expect(external.tcpPort, localTcp + 5);
      expect(external.toJson().keys, [
        'username',
        'credential',
        'udp_port',
        'tcp_port',
      ]);
    });

    test('grants are unique, expire at ttl and revoke', () async {
      await service.start(portMapping: false);
      final a = service.issueTurnGrant(ttl: const Duration(minutes: 5))!;
      final b = service.issueTurnGrant()!;
      expect(a.username, isNot(b.username));
      expect(a.credential, isNot(b.credential));
      expect(a.expiresAt, now.add(const Duration(minutes: 5)));
      expect(b.expiresAt, now.add(const Duration(hours: 12)));
      expect(a.username.length, 22); // 16 random bytes, base64url
      expect(a.credential.length, 32); // 24 random bytes, base64url
      service.revokeTurnGrant(a); // must not throw
    });

    test('issued credentials work against the real embedded server', () async {
      await service.start(portMapping: false);
      final grant = service.issueTurnGrant()!;
      final c = await TurnTestClient.udp(grant.udpPort);
      addTearDown(c.close);

      final alloc = await c.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.credential,
      );
      expect(alloc.messageClass, StunClass.success);
      // XOR-RELAYED-ADDRESS is the machine's primary LAN address.
      expect(
        alloc.xorAddress(StunAttr.xorRelayedAddress)!.address.address,
        '192.168.1.50',
      );

      // Permissions only for addresses of this machine.
      final own = await c.authed(
        StunMethod.createPermission,
        [peerAttr('192.168.1.50', 40000)],
        grant.username,
        grant.credential,
      );
      expect(own.messageClass, StunClass.success);
      final loop = await c.authed(
        StunMethod.createPermission,
        [peerAttr('127.0.0.1', 40000)],
        grant.username,
        grant.credential,
      );
      expect(loop.messageClass, StunClass.success);
      final foreign = await c.authed(
        StunMethod.createPermission,
        [peerAttr('8.8.8.8', 40000)],
        grant.username,
        grant.credential,
      );
      expect(foreign.errorCode!.code, 403);
    });

    test('a revoked grant dies 60 seconds later', () async {
      await service.start(portMapping: false);
      final grant = service.issueTurnGrant()!;
      service.revokeTurnGrant(grant);

      now = now.add(const Duration(seconds: 59));
      final within = await TurnTestClient.udp(grant.udpPort);
      addTearDown(within.close);
      var r = await within.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.credential,
      );
      expect(r.messageClass, StunClass.success);

      now = now.add(const Duration(seconds: 2));
      final late = await TurnTestClient.udp(grant.udpPort);
      addTearDown(late.close);
      r = await late.authed(
        StunMethod.allocate,
        [transportUdp()],
        grant.username,
        grant.credential,
      );
      expect(r.errorCode!.code, 401);
    });

    test(
      'a peer on a freshly joined network is accepted after a re-scan',
      () async {
        await service.start(portMapping: false);
        final grant = service.issueTurnGrant()!;
        final c = await TurnTestClient.udp(grant.udpPort);
        addTearDown(c.close);
        await c.authed(
          StunMethod.allocate,
          [transportUdp()],
          grant.username,
          grant.credential,
        );

        interfaces = [
          LocalInterface('en0', [
            InternetAddress('192.168.1.50'),
            InternetAddress('10.9.9.9'),
          ]),
        ];
        var r = await c.authed(
          StunMethod.createPermission,
          [peerAttr('10.9.9.9', 4000)],
          grant.username,
          grant.credential,
        );
        expect(
          r.errorCode!.code,
          403,
          reason: 'cache is fresh, no re-scan yet',
        );

        now = now.add(const Duration(seconds: 6));
        final fresh = service.issueTurnGrant()!;
        final c2 = await TurnTestClient.udp(fresh.udpPort);
        addTearDown(c2.close);
        await c2.authed(
          StunMethod.allocate,
          [transportUdp()],
          fresh.username,
          fresh.credential,
        );
        r = await c2.authed(
          StunMethod.createPermission,
          [peerAttr('10.9.9.9', 4000)],
          fresh.username,
          fresh.credential,
        );
        expect(r.messageClass, StunClass.success);
      },
    );
  });
}
