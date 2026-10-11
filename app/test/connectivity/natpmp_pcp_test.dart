import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/net/connectivity/connectivity.dart';
import 'package:thelxis/net/connectivity/natpmp.dart';
import 'package:thelxis/net/connectivity/pcp.dart';
import 'package:thelxis/net/connectivity/port_mapping.dart';

import 'fake_gateway.dart';

const _fast = [Duration(milliseconds: 120), Duration(milliseconds: 240)];
final _lo = InternetAddress.loopbackIPv4;

void main() {
  group('NAT-PMP', () {
    late FakePmpGateway gw;
    setUp(() async => gw = await FakePmpGateway.start());
    tearDown(() => gw.close());

    NatPmpClient client() =>
        NatPmpClient(_lo, port: gw.port, bindAddress: _lo, retries: _fast);

    test('probe succeeds and reads the external address', () async {
      final c = await NatPmpClient.probe(
        _lo,
        port: gw.port,
        bindAddress: _lo,
        retries: _fast,
      );
      expect(c, isNotNull);
      expect(c!.method, MappingMethod.natPmp);
      expect((await c.externalAddress())!.address, '93.184.216.34');
      expect(gw.requests.first, [0, 0]);
    });

    test('probe returns null without a router', () async {
      gw.silent = true;
      final c = await NatPmpClient.probe(
        _lo,
        port: gw.port,
        bindAddress: _lo,
        retries: _fast,
      );
      expect(c, isNull);
    });

    test(
      'a PCP-only router (unsupported version) is not a NAT-PMP router',
      () async {
        gw.resultCode = 1;
        final c = await NatPmpClient.probe(
          _lo,
          port: gw.port,
          bindAddress: _lo,
          retries: _fast,
        );
        expect(c, isNull);
      },
    );

    test('maps TCP and UDP with the right wire format', () async {
      final c = client();
      final tcp = await c.map(
        protocol: MappingProtocol.tcp,
        internalPort: 47100,
        suggestedExternalPort: 47100,
        lifetime: const Duration(hours: 1),
      );
      expect(tcp.externalPort, 47100);
      expect(tcp.lifetime, const Duration(hours: 1));
      final req = gw.requests.last;
      expect(req.length, 12);
      expect(req[0], 0);
      expect(req[1], 2); // TCP
      expect(ByteData.sublistView(req).getUint16(4), 47100);
      expect(ByteData.sublistView(req).getUint16(6), 47100);
      expect(ByteData.sublistView(req).getUint32(8), 3600);

      await c.map(
        protocol: MappingProtocol.udp,
        internalPort: 47100,
        suggestedExternalPort: 47100,
        lifetime: const Duration(hours: 1),
      );
      expect(gw.requests.last[1], 1); // UDP
    });

    test('uses the external port the router assigned', () async {
      gw.portShift = 7;
      final g = await client().map(
        protocol: MappingProtocol.tcp,
        internalPort: 47100,
        suggestedExternalPort: 47100,
        lifetime: const Duration(hours: 1),
      );
      expect(g.externalPort, 47107);
    });

    test('reports the lifetime the router granted', () async {
      gw.lifetimeCap = 600;
      final g = await client().map(
        protocol: MappingProtocol.tcp,
        internalPort: 47100,
        suggestedExternalPort: 47100,
        lifetime: const Duration(hours: 1),
      );
      expect(g.lifetime, const Duration(seconds: 600));
    });

    test('unmap sends lifetime 0 and external port 0', () async {
      await client().unmap(
        protocol: MappingProtocol.tcp,
        internalPort: 47100,
        externalPort: 47100,
      );
      final req = gw.requests.last;
      expect(ByteData.sublistView(req).getUint16(4), 47100);
      expect(ByteData.sublistView(req).getUint16(6), 0);
      expect(ByteData.sublistView(req).getUint32(8), 0);
    });

    test(
      'a refusal surfaces as MappingException with the result code',
      () async {
        gw.resultCode = 2;
        await expectLater(
          client().map(
            protocol: MappingProtocol.tcp,
            internalPort: 47100,
            suggestedExternalPort: 47100,
            lifetime: const Duration(hours: 1),
          ),
          throwsA(isA<MappingException>().having((e) => e.code, 'code', 2)),
        );
      },
    );

    test('replies from another source port are ignored', () async {
      gw.sendBogusFirst = true;
      final g = await client().map(
        protocol: MappingProtocol.tcp,
        internalPort: 47100,
        suggestedExternalPort: 47100,
        lifetime: const Duration(hours: 1),
      );
      expect(g.externalPort, 47100);
    });

    test('a silent router makes map throw', () async {
      gw.silent = true;
      await expectLater(
        client().map(
          protocol: MappingProtocol.tcp,
          internalPort: 47100,
          suggestedExternalPort: 47100,
          lifetime: const Duration(hours: 1),
        ),
        throwsA(isA<MappingException>()),
      );
    });
  });

  group('PCP', () {
    late FakePcpGateway gw;
    setUp(() async => gw = await FakePcpGateway.start());
    tearDown(() => gw.close());

    PcpClient client() => PcpClient(_lo, _lo, port: gw.port, retries: _fast);

    test('probe uses ANNOUNCE and recognises a PCP router', () async {
      final c = await PcpClient.probe(_lo, _lo, port: gw.port, retries: _fast);
      expect(c, isNotNull);
      final req = gw.requests.first;
      expect(req.length, 24);
      expect(req[0], 2);
      expect(req[1], 0);
    });

    test('a NAT-PMP-only router is rejected quickly', () async {
      gw.natPmpOnly = true;
      final started = DateTime.now();
      final c = await PcpClient.probe(_lo, _lo, port: gw.port, retries: _fast);
      expect(c, isNull);
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(milliseconds: 300)),
      );
    });

    test('no router: probe returns null', () async {
      gw.silent = true;
      expect(
        await PcpClient.probe(_lo, _lo, port: gw.port, retries: _fast),
        isNull,
      );
    });

    test('MAP request layout and response parsing', () async {
      final c = client();
      final g = await c.map(
        protocol: MappingProtocol.tcp,
        internalPort: 47100,
        suggestedExternalPort: 47100,
        lifetime: const Duration(hours: 1),
      );
      expect(g.externalPort, 47100);
      expect(g.lifetime, const Duration(hours: 1));
      expect((await c.externalAddress())!.address, '93.184.216.34');

      final req = gw.requests.last;
      final view = ByteData.sublistView(req);
      expect(req.length, 60);
      expect(req[0], 2); // version
      expect(req[1], 1); // MAP, R=0
      expect(view.getUint32(4), 3600);
      // client address as IPv4-mapped IPv6
      expect(req.sublist(8, 20), [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff]);
      expect(req.sublist(20, 24), [127, 0, 0, 1]);
      expect(req[36], 6); // TCP
      expect(view.getUint16(40), 47100);
      expect(view.getUint16(42), 47100);
      expect(req.sublist(44, 60), Uint8List(16)); // any external address
    });

    test('UDP protocol number and router-chosen port', () async {
      gw.portShift = 3;
      final g = await client().map(
        protocol: MappingProtocol.udp,
        internalPort: 47100,
        suggestedExternalPort: 47100,
        lifetime: const Duration(hours: 1),
      );
      expect(gw.requests.last[36], 17);
      expect(g.externalPort, 47103);
    });

    test('unmap reuses the nonce with lifetime 0', () async {
      final c = client();
      await c.map(
        protocol: MappingProtocol.tcp,
        internalPort: 47100,
        suggestedExternalPort: 47100,
        lifetime: const Duration(hours: 1),
      );
      final createNonce = gw.requests.last.sublist(24, 36);
      await c.unmap(
        protocol: MappingProtocol.tcp,
        internalPort: 47100,
        externalPort: 47100,
      );
      final del = gw.requests.last;
      expect(ByteData.sublistView(del).getUint32(4), 0);
      expect(del.sublist(24, 36), createNonce);
    });

    test('different mappings use different nonces', () async {
      final c = client();
      for (final p in [MappingProtocol.tcp, MappingProtocol.udp]) {
        await c.map(
          protocol: p,
          internalPort: 47100,
          suggestedExternalPort: 47100,
          lifetime: const Duration(hours: 1),
        );
      }
      expect(
        gw.requests[0].sublist(24, 36),
        isNot(gw.requests[1].sublist(24, 36)),
      );
    });

    test('an error result surfaces with its code', () async {
      gw.resultCode = 11;
      await expectLater(
        client().map(
          protocol: MappingProtocol.tcp,
          internalPort: 47100,
          suggestedExternalPort: 47100,
          lifetime: const Duration(hours: 1),
        ),
        throwsA(
          isA<MappingException>()
              .having((e) => e.code, 'code', 11)
              .having((e) => e.message, 'message', contains('external port')),
        ),
      );
    });

    test('a reply with the wrong nonce is ignored', () async {
      gw.corruptNonce = true;
      await expectLater(
        client().map(
          protocol: MappingProtocol.tcp,
          internalPort: 47100,
          suggestedExternalPort: 47100,
          lifetime: const Duration(hours: 1),
        ),
        throwsA(isA<MappingException>()),
      );
    });

    test('candidate ordering puts the best match first', () {
      final locals = [
        InternetAddress('10.0.0.2'),
        InternetAddress('192.168.1.9'),
      ];
      final c = pcpLocalCandidates(InternetAddress('192.168.1.1'), locals);
      expect(c.map((a) => a.address), ['192.168.1.9', '10.0.0.2']);
    });
  });
}
