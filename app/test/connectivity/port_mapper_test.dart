import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/net/connectivity/connectivity.dart';
import 'package:thelxis/net/connectivity/interfaces.dart';
import 'package:thelxis/net/connectivity/port_mapper.dart';
import 'package:thelxis/net/connectivity/port_mapping.dart';
import 'package:thelxis/net/connectivity/upnp.dart';

import 'fake_igd.dart';
import 'fake_mapping.dart';

const _targets = [
  MappingTarget(MappingProtocol.tcp, 47100),
  MappingTarget(MappingProtocol.udp, 47100),
  MappingTarget(MappingProtocol.tcp, 47101),
];

DiscoveryContext _ctx() => DiscoveryContext(locals: const LocalAddresses());

void main() {
  test(
    'tries UPnP, then PCP, then NAT-PMP and stops at the first success',
    () async {
      final upnp = CountingProbe(MappingMethod.upnp);
      final pcp = CountingProbe(
        MappingMethod.pcp,
        router: FakeRouter(MappingMethod.pcp),
      );
      final pmp = CountingProbe(
        MappingMethod.natPmp,
        router: FakeRouter(MappingMethod.natPmp),
      );
      final mapper = PortMapper(probes: [upnp.probe, pcp.probe, pmp.probe]);

      final outcome = await mapper.establish(_ctx(), _targets);

      expect(outcome.mapped, isTrue);
      expect(outcome.client!.method, MappingMethod.pcp);
      expect([upnp.calls, pcp.calls, pmp.calls], [1, 1, 0]);
      expect(
        outcome.mappings.map(
          (m) => '${m.protocol.name}:${m.internalPort}->${m.externalPort}',
        ),
        ['tcp:47100->47100', 'udp:47100->47100', 'tcp:47101->47101'],
      );
      expect(outcome.externalAddress!.address, '93.184.216.34');
      expect(outcome.gatewayFound, isTrue);
    },
  );

  test('UPnP wins when it works', () async {
    final upnp = CountingProbe(
      MappingMethod.upnp,
      router: FakeRouter(MappingMethod.upnp),
    );
    final pcp = CountingProbe(
      MappingMethod.pcp,
      router: FakeRouter(MappingMethod.pcp),
    );
    final outcome = await PortMapper(probes: [upnp.probe, pcp.probe])
        .establish(_ctx(), _targets);
    expect(outcome.client!.method, MappingMethod.upnp);
    expect(pcp.calls, 0);
  });

  test(
    'a router that refuses the signaling port falls through to the next method',
    () async {
      final stubborn = FakeRouter(MappingMethod.upnp)..refuse.add('tcp:47100');
      final upnp = CountingProbe(MappingMethod.upnp, router: stubborn);
      final pmp = CountingProbe(
        MappingMethod.natPmp,
        router: FakeRouter(MappingMethod.natPmp, id: 'router-2'),
      );
      final outcome = await PortMapper(probes: [upnp.probe, pmp.probe])
          .establish(_ctx(), _targets);

      expect(outcome.client!.method, MappingMethod.natPmp);
      expect(outcome.gatewayFound, isTrue);
      expect(
        outcome.problems,
        isEmpty,
        reason: 'an earlier method\'s refusal is noise once another one works',
      );
      expect(stubborn.mapCalls, [
        'tcp:47100',
      ], reason: 'gave up after the first refusal');
      expect(stubborn.closed, isTrue);
    },
  );

  test('all methods refusing keeps the WAN address for diagnostics', () async {
    final r = FakeRouter(MappingMethod.upnp, external: '100.72.5.6')
      ..refuse.add('tcp:47100');
    final outcome = await PortMapper(
      probes: [CountingProbe(MappingMethod.upnp, router: r).probe],
    ).establish(_ctx(), _targets);
    expect(outcome.mapped, isFalse);
    expect(outcome.client, isNull);
    expect(outcome.gatewayFound, isTrue);
    expect(outcome.externalAddress!.address, '100.72.5.6');
    expect(outcome.problems.single, contains('UPnP could not map TCP 47100'));
  });

  test('no router at all', () async {
    final outcome = await PortMapper(
      probes: [
        CountingProbe(MappingMethod.upnp).probe,
        CountingProbe(MappingMethod.pcp).probe,
        CountingProbe(MappingMethod.natPmp).probe,
      ],
    ).establish(_ctx(), _targets);
    expect(outcome.mapped, isFalse);
    expect(outcome.gatewayFound, isFalse);
    expect(outcome.problems, isEmpty);
  });

  test('a probe that throws does not stop the others', () async {
    final boom = CountingProbe(MappingMethod.upnp, throws: true);
    final ok = CountingProbe(
      MappingMethod.pcp,
      router: FakeRouter(MappingMethod.pcp),
    );
    final outcome = await PortMapper(probes: [boom.probe, ok.probe])
        .establish(_ctx(), _targets);
    expect(outcome.client!.method, MappingMethod.pcp);
  });

  test('secondary mappings are best effort', () async {
    final r = FakeRouter(MappingMethod.upnp)..refuse.add('udp:47100');
    final outcome = await PortMapper(
      probes: [CountingProbe(MappingMethod.upnp, router: r).probe],
    ).establish(_ctx(), _targets);
    expect(outcome.mapped, isTrue);
    expect(outcome.mappings, hasLength(2));
    expect(outcome.problems.single, contains('UDP 47100'));
  });

  test('router-chosen external ports are recorded', () async {
    final r = FakeRouter(MappingMethod.natPmp)..portShift = 10;
    final outcome = await PortMapper(
      probes: [CountingProbe(MappingMethod.natPmp, router: r).probe],
    ).establish(_ctx(), _targets);
    expect(outcome.mappings.first.externalPort, 47110);
    expect(
      outcome.mappings.first.toPortMapping(MappingMethod.natPmp).externalPort,
      47110,
    );
  });

  test('renew re-requests every mapping and follows port changes', () async {
    final r = FakeRouter(MappingMethod.upnp);
    final mapper = PortMapper(
      probes: [CountingProbe(MappingMethod.upnp, router: r).probe],
    );
    final outcome = await mapper.establish(_ctx(), _targets);
    r.mapCalls.clear();
    r.portShift = 5;
    await mapper.renew(outcome);
    expect(r.mapCalls, ['tcp:47100', 'udp:47100', 'tcp:47101']);
    expect(outcome.mappings.first.externalPort, 47105);
  });

  test('renew throws when the signaling mapping cannot be renewed', () async {
    final r = FakeRouter(MappingMethod.upnp);
    final mapper = PortMapper(
      probes: [CountingProbe(MappingMethod.upnp, router: r).probe],
    );
    final outcome = await mapper.establish(_ctx(), _targets);
    r.failMaps = true;
    await expectLater(mapper.renew(outcome), throwsA(isA<MappingException>()));
  });

  test('remove unmaps everything', () async {
    final r = FakeRouter(MappingMethod.upnp);
    final mapper = PortMapper(
      probes: [CountingProbe(MappingMethod.upnp, router: r).probe],
    );
    final outcome = await mapper.establish(_ctx(), _targets);
    await mapper.remove(outcome);
    expect(
      r.unmapCalls,
      unorderedEquals([
        'tcp:47100->47100',
        'udp:47100->47100',
        'tcp:47101->47101',
      ]),
    );
    expect(r.closed, isTrue);
  });

  test('PortMapper drives a real UPnP client against a fake IGD', () async {
    final igd = await FakeIgd.start();
    addTearDown(igd.close);
    igd.addPortMappingErrors.addAll([null, 718]); // TCP ok, UDP conflicts once
    final mapper = PortMapper(
      probes: [
        MappingProbe(MappingMethod.upnp, (ctx) {
          return UpnpDiscovery(
            interfaces: [
              LocalInterface('lo0', [InternetAddress.loopbackIPv4]),
            ],
            multicastAddress: InternetAddress.loopbackIPv4,
            ssdpPort: igd.ssdpPort,
            ssdpTimeout: const Duration(seconds: 2),
            allowLoopback: true,
          ).discover();
        }),
      ],
    );

    final outcome = await mapper.establish(_ctx(), _targets);

    expect(outcome.mapped, isTrue);
    expect(outcome.externalAddress!.address, '93.184.216.34');
    expect(
      outcome.mappings.map(
        (m) => '${m.protocol.name}:${m.internalPort}->${m.externalPort}',
      ),
      ['tcp:47100->47100', 'udp:47100->47110', 'tcp:47101->47101'],
    );
    expect(igd.mappings, {
      'TCP:47100': 47100,
      'UDP:47110': 47100,
      'TCP:47101': 47101,
    });

    await mapper.remove(outcome);
    expect(igd.mappings, isEmpty);
  });

  test(
    'mappings keep one offset when another PC owns the first port',
    () async {
      final igd = await FakeIgd.start();
      addTearDown(igd.close);
      igd.preload('TCP', 47100); // a second PC behind the same router
      igd.overwriteForeign = true;
      final mapper = PortMapper(
        probes: [
          MappingProbe(MappingMethod.upnp, (ctx) {
            return UpnpDiscovery(
              interfaces: [
                LocalInterface('lo0', [InternetAddress.loopbackIPv4]),
              ],
              multicastAddress: InternetAddress.loopbackIPv4,
              ssdpPort: igd.ssdpPort,
              ssdpTimeout: const Duration(seconds: 2),
              allowLoopback: true,
            ).discover();
          }),
        ],
      );

      final outcome = await mapper.establish(_ctx(), _targets);

      expect(
        outcome.mappings.map(
          (m) => '${m.protocol.name}:${m.internalPort}->${m.externalPort}',
        ),
        ['tcp:47100->47110', 'udp:47100->47110', 'tcp:47101->47111'],
      );
      expect(igd.entries['TCP:47100']!.client, '192.168.1.99');
    },
  );
}
