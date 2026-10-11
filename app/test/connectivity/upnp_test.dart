import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/net/connectivity/connectivity.dart';
import 'package:thelxis/net/connectivity/interfaces.dart';
import 'package:thelxis/net/connectivity/port_mapping.dart';
import 'package:thelxis/net/connectivity/upnp.dart';
import 'package:thelxis/net/connectivity/xml_lite.dart';

import 'fake_igd.dart';

UpnpDiscovery _discovery(
  FakeIgd igd, {
  Duration ssdpTimeout = const Duration(seconds: 2),
}) => UpnpDiscovery(
  interfaces: [
    LocalInterface('lo0', [InternetAddress.loopbackIPv4]),
  ],
  multicastAddress: InternetAddress.loopbackIPv4,
  ssdpPort: igd.ssdpPort,
  ssdpTimeout: ssdpTimeout,
  httpTimeout: const Duration(seconds: 2),
  allowLoopback: true,
);

void main() {
  group('lenient XML', () {
    test('handles sloppy documents', () {
      const messy = '''
<?xml version="1.0"?>
<!-- a comment with <tags> inside -->
<ROOT xmlns="x"><Service a=">" b='1'><ServiceType>urn:a &amp; b</ServiceType>
<controlURL><![CDATA[/ctl?x=1&y=2]]></controlURL>
<Unclosed>text
</Service><S:Other xmlns:S="y"><S:Inner>v</S:Inner></S:Other>
<empty/><n>&#65;&#x42;&bogus;</n>
</ROOT>''';
      final doc = parseXmlLenient(messy);
      expect(doc.textOf('servicetype'), 'urn:a & b');
      expect(doc.textOf('controlURL'), '/ctl?x=1&y=2');
      expect(doc.textOf('Inner'), 'v');
      expect(doc.textOf('n'), 'AB&bogus;');
      expect(doc.find('empty'), isNotNull);
      expect(doc.textOf('Unclosed'), 'text');
    });

    test('never throws on garbage', () {
      for (final s in [
        '',
        '<',
        '<<<>>>',
        '</x>',
        '<a><b></a>',
        '<a b="c',
        '\u0000<',
      ]) {
        expect(() => parseXmlLenient(s), returnsNormally, reason: s);
      }
    });

    test('absurd nesting is capped instead of overflowing the stack', () {
      final bomb = '<a>' * 200000;
      final doc = parseXmlLenient(bomb);
      expect(doc.find('a'), isNotNull);
      expect(
        doc.textOf('missing'),
        isNull,
      ); // recursion over the tree terminates
    });

    test('xmlEscape', () {
      expect(xmlEscape('a<b>&"c'), 'a&lt;b&gt;&amp;&quot;c');
    });
  });

  group('SSDP parsing', () {
    test('accepts a 200 OK reply and lower-cases header names', () {
      final h = parseSsdpResponse(
        ascii.encode(
          'HTTP/1.1 200 OK\r\n'
          'Location: http://192.168.1.1:5000/rootDesc.xml\r\n'
          'ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n',
        ),
      );
      expect(h!['location'], 'http://192.168.1.1:5000/rootDesc.xml');
    });

    test('rejects NOTIFY and garbage', () {
      expect(
        parseSsdpResponse(ascii.encode('NOTIFY * HTTP/1.1\r\n\r\n')),
        isNull,
      );
      expect(parseSsdpResponse([0xff, 0xfe, 0x00]), isNull);
      expect(parseSsdpResponse(<int>[]), isNull);
    });

    test('M-SEARCH request is well formed', () {
      final text = ascii.decode(buildMSearch(ssdpSearchTargets.first));
      expect(text, startsWith('M-SEARCH * HTTP/1.1\r\n'));
      expect(text, contains('HOST: 239.255.255.250:1900\r\n'));
      expect(text, contains('MAN: "ssdp:discover"\r\n'));
      expect(text, contains('MX: 2\r\n'));
      expect(text, endsWith('\r\n\r\n'));
      expect(
        ssdpSearchTargets,
        containsAll([
          'urn:schemas-upnp-org:device:InternetGatewayDevice:1',
          'urn:schemas-upnp-org:device:InternetGatewayDevice:2',
          'urn:schemas-upnp-org:service:WANIPConnection:1',
          'urn:schemas-upnp-org:service:WANIPConnection:2',
          'urn:schemas-upnp-org:service:WANPPPConnection:1',
        ]),
      );
    });
  });

  group('device description', () {
    final location = Uri.parse('http://192.168.1.1:5000/rootDesc.xml');

    test('relative controlURL resolves against LOCATION', () {
      final s = parseIgdDescription(igdDescription(), location);
      expect(s, hasLength(1));
      expect(
        s.single.controlUrl.toString(),
        'http://192.168.1.1:5000/ctl/IPConn',
      );
      expect(s.single.serviceType, wanIpService);
    });

    test('URLBase wins when it is a LAN address', () {
      final s = parseIgdDescription(
        igdDescription(urlBase: '<URLBase>http://192.168.1.1:49152/</URLBase>'),
        location,
      );
      expect(
        s.single.controlUrl.toString(),
        'http://192.168.1.1:49152/ctl/IPConn',
      );
    });

    test('a public URLBase is ignored', () {
      final s = parseIgdDescription(
        igdDescription(urlBase: '<URLBase>http://8.8.8.8:80/</URLBase>'),
        location,
      );
      expect(s.single.controlUrl.host, '192.168.1.1');
      expect(s.single.controlUrl.port, 5000);
    });

    test('absolute controlURL on another public host is steered back', () {
      final s = parseIgdDescription(
        igdDescription(controlUrl: 'http://8.8.8.8/ctl/IPConn'),
        location,
      );
      expect(s.single.controlUrl.host, '192.168.1.1');
      expect(s.single.controlUrl.path, '/ctl/IPConn');
    });

    test('services are ranked WANIPConnection:2, :1, WANPPPConnection', () {
      const xml = '''
<root><device><serviceList>
<service><serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType><controlURL>/ppp</controlURL></service>
<service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType><controlURL>/ip1</controlURL></service>
<service><serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType><controlURL>/l3</controlURL></service>
<service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:2</serviceType><controlURL>/ip2</controlURL></service>
</serviceList></device></root>''';
      final s = parseIgdDescription(xml, location);
      expect(s.map((e) => e.controlUrl.path), ['/ip2', '/ip1', '/ppp']);
    });

    test('tolerates missing end tags and odd case', () {
      const xml = '''
<ROOT><DEVICE><SERVICELIST>
<SERVICE><SERVICETYPE>urn:schemas-upnp-org:service:WANIPConnection:1</SERVICETYPE>
<CONTROLURL>/ctl
<SERVICE><SERVICETYPE>urn:schemas-upnp-org:service:WANPPPConnection:1</SERVICETYPE>
<CONTROLURL>/ppp</CONTROLURL>''';
      final s = parseIgdDescription(xml, location);
      expect(s, isNotEmpty);
      expect(s.first.serviceType, contains('WANIPConnection'));
    });

    test('no IGD service yields nothing', () {
      expect(parseIgdDescription('<root><device/></root>', location), isEmpty);
      expect(parseIgdDescription('', location), isEmpty);
    });
  });

  group('SOAP', () {
    test('envelope carries escaped arguments in order', () {
      final xml = buildSoapEnvelope(wanIpService, 'AddPortMapping', [
        ('NewRemoteHost', ''),
        ('NewPortMappingDescription', 'A&B'),
      ]);
      expect(xml, contains('<u:AddPortMapping xmlns:u="$wanIpService">'));
      expect(xml, contains('<NewRemoteHost></NewRemoteHost>'));
      expect(
        xml,
        contains(
          '<NewPortMappingDescription>A&amp;B</NewPortMappingDescription>',
        ),
      );
      expect(
        xml.indexOf('NewRemoteHost'),
        lessThan(xml.indexOf('NewPortMappingDescription')),
      );
    });
  });

  group('against a fake router', () {
    late FakeIgd igd;
    UpnpGateway? gateway;

    setUp(() async => igd = await FakeIgd.start());
    tearDown(() async {
      gateway?.close();
      gateway = null;
      await igd.close();
    });

    test(
      'SSDP finds the router, reads the WAN address and maps ports',
      () async {
        gateway = await _discovery(igd).discover();
        expect(gateway, isNotNull);
        expect(gateway!.method, MappingMethod.upnp);
        expect((await gateway!.externalAddress())!.address, '93.184.216.34');

        final grant = await gateway!.map(
          protocol: MappingProtocol.tcp,
          internalPort: 47100,
          suggestedExternalPort: 47100,
          lifetime: const Duration(hours: 1),
        );
        expect(grant.externalPort, 47100);
        expect(grant.lifetime, const Duration(hours: 1));

        final add = igd.calls.firstWhere((c) => c.action == 'AddPortMapping');
        expect(add.soapAction, '$wanIpService#AddPortMapping');
        expect(add.args, {
          'NewRemoteHost': '',
          'NewExternalPort': '47100',
          'NewProtocol': 'TCP',
          'NewInternalPort': '47100',
          'NewInternalClient': '127.0.0.1',
          'NewEnabled': '1',
          'NewPortMappingDescription': 'Thelxis',
          'NewLeaseDuration': '3600',
        });
        expect(igd.mappings, {'TCP:47100': 47100});
        expect(igd.searchTargets.toSet(), containsAll(ssdpSearchTargets));
      },
    );

    test('UDP mapping uses protocol UDP', () async {
      gateway = await _discovery(igd).discover();
      await gateway!.map(
        protocol: MappingProtocol.udp,
        internalPort: 47100,
        suggestedExternalPort: 47100,
        lifetime: const Duration(hours: 1),
      );
      expect(igd.calls.last.args['NewProtocol'], 'UDP');
    });

    test('error 725 retries with a permanent lease', () async {
      igd.addPortMappingErrors.add(725);
      gateway = await _discovery(igd).discover();
      final grant = await gateway!.map(
        protocol: MappingProtocol.tcp,
        internalPort: 47100,
        suggestedExternalPort: 47100,
        lifetime: const Duration(hours: 1),
      );
      final adds = igd.calls
          .where((c) => c.action == 'AddPortMapping')
          .toList();
      expect(adds.map((c) => c.args['NewLeaseDuration']), ['3600', '0']);
      expect(grant.lifetime, Duration.zero);
      expect(grant.externalPort, 47100);
    });

    test('after a 725 the router is not asked for leases again', () async {
      igd.addPortMappingErrors.add(725);
      gateway = await _discovery(igd).discover();
      for (final p in [MappingProtocol.tcp, MappingProtocol.udp]) {
        await gateway!.map(
          protocol: p,
          internalPort: 47100,
          suggestedExternalPort: 47100,
          lifetime: const Duration(hours: 1),
        );
      }
      final leases = igd.calls
          .where((c) => c.action == 'AddPortMapping')
          .map((c) => c.args['NewLeaseDuration'])
          .toList();
      expect(leases, ['3600', '0', '0']);
    });

    test('error 718 moves the external port by 10, 20, ...', () async {
      igd.addPortMappingErrors.addAll([718, 718]);
      gateway = await _discovery(igd).discover();
      final grant = await gateway!.map(
        protocol: MappingProtocol.tcp,
        internalPort: 47100,
        suggestedExternalPort: 47100,
        lifetime: const Duration(hours: 1),
      );
      final ports = igd.calls
          .where((c) => c.action == 'AddPortMapping')
          .map((c) => c.args['NewExternalPort'])
          .toList();
      expect(ports, ['47100', '47110', '47120']);
      expect(grant.externalPort, 47120);
      expect(igd.mappings, {'TCP:47120': 47100});
    });

    test('error 718 gives up after five attempts', () async {
      igd.addPortMappingErrors.addAll(List.filled(10, 718));
      gateway = await _discovery(igd).discover();
      await expectLater(
        gateway!.map(
          protocol: MappingProtocol.tcp,
          internalPort: 47100,
          suggestedExternalPort: 47100,
          lifetime: const Duration(hours: 1),
        ),
        throwsA(isA<MappingException>().having((e) => e.code, 'code', 718)),
      );
      final ports = igd.calls
          .where((c) => c.action == 'AddPortMapping')
          .map((c) => c.args['NewExternalPort'])
          .toList();
      expect(ports, ['47100', '47110', '47120', '47130', '47140']);
    });

    test('other UPnP errors surface with their code', () async {
      igd.addPortMappingErrors.add(729);
      gateway = await _discovery(igd).discover();
      await expectLater(
        gateway!.map(
          protocol: MappingProtocol.tcp,
          internalPort: 47100,
          suggestedExternalPort: 47100,
          lifetime: const Duration(hours: 1),
        ),
        throwsA(
          isA<MappingException>()
              .having((e) => e.code, 'code', 729)
              .having((e) => e.message, 'message', contains('AddPortMapping')),
        ),
      );
    });

    test('DeletePortMapping removes the entry; 714 counts as done', () async {
      gateway = await _discovery(igd).discover();
      await gateway!.map(
        protocol: MappingProtocol.tcp,
        internalPort: 47100,
        suggestedExternalPort: 47100,
        lifetime: const Duration(hours: 1),
      );
      await gateway!.unmap(
        protocol: MappingProtocol.tcp,
        internalPort: 47100,
        externalPort: 47100,
      );
      expect(igd.mappings, isEmpty);
      final del = igd.calls.firstWhere((c) => c.action == 'DeletePortMapping');
      expect(del.args, {
        'NewRemoteHost': '',
        'NewExternalPort': '47100',
        'NewProtocol': 'TCP',
      });

      igd.deleteError = 714;
      await gateway!.unmap(
        protocol: MappingProtocol.tcp,
        internalPort: 47100,
        externalPort: 47100,
      );
      igd.deleteError = 501;
      await expectLater(
        gateway!.unmap(
          protocol: MappingProtocol.tcp,
          internalPort: 47100,
          externalPort: 47100,
        ),
        throwsA(isA<MappingException>()),
      );
    });

    test(
      'a router answering 0.0.0.0 is still usable but has no WAN address',
      () async {
        igd.externalIp = '0.0.0.0';
        gateway = await _discovery(igd).discover();
        expect(gateway, isNotNull);
        expect(await gateway!.externalAddress(), isNull);
      },
    );

    test('works with a sloppy description and a URLBase', () async {
      await igd.close();
      igd = await FakeIgd.start(
        description: (base) =>
            '<root><URLBase>http://127.0.0.1:${base.port}/</URLBase><device>'
            '<service><serviceType>$wanIpService</serviceType>'
            '<controlURL>/ctl/IPConn</controlURL>',
      );
      gateway = await _discovery(igd).discover();
      expect(gateway, isNotNull);
      expect((await gateway!.externalAddress())!.address, igd.externalIp);
    });

    test('no answer: discovery returns null after the SSDP timeout', () async {
      igd.answerSsdp = false;
      final started = DateTime.now();
      gateway = await _discovery(
        igd,
        ssdpTimeout: const Duration(milliseconds: 600),
      ).discover();
      expect(gateway, isNull);
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 3)),
      );
    });

    test('a LOCATION on a public host is ignored', () async {
      igd.locationOverride = 'http://8.8.8.8/rootDesc.xml';
      gateway = await _discovery(
        igd,
        ssdpTimeout: const Duration(milliseconds: 600),
      ).discover();
      expect(gateway, isNull);
    });

    test('unicast targets are searched too', () async {
      final discovery = UpnpDiscovery(
        interfaces: [
          LocalInterface('lo0', [InternetAddress.loopbackIPv4]),
        ],
        // multicast goes nowhere; only the unicast probe reaches the router
        multicastAddress: InternetAddress('127.0.0.2'),
        unicastTargets: [InternetAddress.loopbackIPv4],
        ssdpPort: igd.ssdpPort,
        ssdpTimeout: const Duration(seconds: 2),
        httpTimeout: const Duration(seconds: 2),
        allowLoopback: true,
      );
      gateway = await discovery.discover();
      expect(gateway, isNotNull);
      expect(discovery.respondingRouters.single, InternetAddress.loopbackIPv4);
    });

    test('no usable interface: discovery gives up immediately', () async {
      final discovery = UpnpDiscovery(
        interfaces: const [],
        allowLoopback: true,
      );
      expect(await discovery.discover(), isNull);
    });
  });
}
