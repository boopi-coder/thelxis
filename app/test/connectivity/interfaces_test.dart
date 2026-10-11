import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/net/connectivity/interfaces.dart';

void main() {
  group('IPv4 classification', () {
    final cases = <String, Ipv4Kind>{
      '10.0.0.1': Ipv4Kind.private,
      '10.255.255.254': Ipv4Kind.private,
      '172.16.0.1': Ipv4Kind.private,
      '172.31.255.255': Ipv4Kind.private,
      '172.15.255.255': Ipv4Kind.publicRoutable,
      '172.32.0.1': Ipv4Kind.publicRoutable,
      '192.168.1.1': Ipv4Kind.private,
      '192.169.0.1': Ipv4Kind.publicRoutable,
      '100.64.0.1': Ipv4Kind.shared,
      '100.127.255.255': Ipv4Kind.shared,
      '100.63.255.255': Ipv4Kind.publicRoutable,
      '100.128.0.1': Ipv4Kind.publicRoutable,
      '169.254.10.20': Ipv4Kind.linkLocal,
      '127.0.0.1': Ipv4Kind.loopback,
      '0.0.0.0': Ipv4Kind.unspecified,
      '224.0.0.251': Ipv4Kind.multicast,
      '239.255.255.250': Ipv4Kind.multicast,
      '240.0.0.1': Ipv4Kind.reserved,
      '255.255.255.255': Ipv4Kind.reserved,
      '192.0.2.1': Ipv4Kind.reserved,
      '198.51.100.7': Ipv4Kind.reserved,
      '203.0.113.5': Ipv4Kind.reserved,
      '198.18.0.1': Ipv4Kind.reserved,
      '8.8.8.8': Ipv4Kind.publicRoutable,
      '93.184.216.34': Ipv4Kind.publicRoutable,
      '1.1.1.1': Ipv4Kind.publicRoutable,
    };
    cases.forEach((ip, kind) {
      test('$ip is $kind', () => expect(classifyIpv4(ip), kind));
    });

    test('isPublicIpv4 accepts only routable literals', () {
      expect(isPublicIpv4('8.8.8.8'), isTrue);
      expect(isPublicIpv4('100.72.1.2'), isFalse);
      expect(isPublicIpv4('192.168.0.2'), isFalse);
      expect(isPublicIpv4(null), isFalse);
      expect(isPublicIpv4('not an ip'), isFalse);
      expect(isPublicIpv4('256.1.1.1'), isFalse);
      expect(isPublicIpv4('1.2.3'), isFalse);
    });
  });

  group('IPv6 classification', () {
    Ipv6Kind kind(String ip) =>
        classifyIpv6Bytes(InternetAddress(ip).rawAddress);
    test('global unicast is 2000::/3 minus tunnels and documentation', () {
      expect(kind('2a00:1450:4001:81b::200e'), Ipv6Kind.globalUnicast);
      expect(kind('2001:4860:4860::8888'), Ipv6Kind.globalUnicast);
      expect(kind('3fff::1'), Ipv6Kind.globalUnicast);
      expect(kind('2002:c000:204::1'), Ipv6Kind.tunnel);
      expect(kind('2001:0:4136:e378:8000:63bf:3fff:fdd2'), Ipv6Kind.tunnel);
      expect(kind('2001:db8::1'), Ipv6Kind.reserved);
    });
    test('private and special ranges are not global', () {
      expect(kind('fd12:3456:789a::1'), Ipv6Kind.uniqueLocal);
      expect(kind('fc00::1'), Ipv6Kind.uniqueLocal);
      expect(kind('fe80::1'), Ipv6Kind.linkLocal);
      expect(kind('febf::1'), Ipv6Kind.linkLocal);
      expect(kind('::1'), Ipv6Kind.loopback);
      expect(kind('::'), Ipv6Kind.unspecified);
      expect(kind('ff02::fb'), Ipv6Kind.multicast);
      expect(kind('::ffff:192.168.1.1'), Ipv6Kind.v4Mapped);
      expect(kind('4000::1'), Ipv6Kind.reserved);
    });
  });

  group('helpers', () {
    test('unmapIpv4 and addressKey see through v4-mapped IPv6', () {
      final mapped = InternetAddress('::ffff:192.168.1.7');
      expect(unmapIpv4(mapped).address, '192.168.1.7');
      expect(addressKey(mapped), addressKey(InternetAddress('192.168.1.7')));
      expect(
        addressKey(InternetAddress('::1')),
        isNot(addressKey(InternetAddress('127.0.0.1'))),
      );
    });

    test('formatHostPort brackets IPv6', () {
      expect(formatHostPort('203.0.113.5', 47100), '203.0.113.5:47100');
      expect(formatHostPort('2a00::1', 47100), '[2a00::1]:47100');
    });

    test('parseIpPort', () {
      expect(parseIpPort('1.2.3.4:5')?.host, '1.2.3.4');
      expect(parseIpPort('1.2.3.4:5')?.port, 5);
      expect(parseIpPort('[2a00::1]:47100')?.host, '2a00::1');
      expect(parseIpPort('[2a00::1]:47100')?.port, 47100);
      expect(parseIpPort('host.example:47100'), isNull);
      expect(parseIpPort('1.2.3.4'), isNull);
      expect(parseIpPort('1.2.3.4:99999'), isNull);
      expect(parseIpPort(null), isNull);
    });

    test('isLanAddress', () {
      expect(isLanAddress(InternetAddress('192.168.1.1')), isTrue);
      expect(isLanAddress(InternetAddress('100.100.1.1')), isTrue);
      expect(isLanAddress(InternetAddress('169.254.1.1')), isTrue);
      expect(isLanAddress(InternetAddress('fd00::1')), isTrue);
      expect(isLanAddress(InternetAddress('8.8.8.8')), isFalse);
      expect(isLanAddress(InternetAddress('2a00::1')), isFalse);
      expect(isLanAddress(InternetAddress('127.0.0.1')), isFalse);
      expect(
        isLanAddress(InternetAddress('127.0.0.1'), allowLoopback: true),
        isTrue,
      );
    });

    test('pickLocalFor prefers the same subnet, then the longest prefix', () {
      final locals = [
        InternetAddress('10.0.0.5'),
        InternetAddress('192.168.1.50'),
        InternetAddress('192.168.7.9'),
      ];
      expect(
        pickLocalFor(InternetAddress('192.168.1.1'), locals)!.address,
        '192.168.1.50',
      );
      expect(
        pickLocalFor(InternetAddress('192.168.7.254'), locals)!.address,
        '192.168.7.9',
      );
      expect(
        pickLocalFor(InternetAddress('10.0.0.1'), locals)!.address,
        '10.0.0.5',
      );
      expect(pickLocalFor(InternetAddress('::1'), locals), isNull);
      expect(pickLocalFor(InternetAddress('192.168.1.1'), const []), isNull);
    });

    test('virtual interface names', () {
      for (final n in [
        'docker0',
        'br-1a2b3c',
        'veth12',
        'virbr0',
        'vmnet8',
        'awdl0',
      ]) {
        expect(isVirtualInterfaceName(n), isTrue, reason: n);
      }
      for (final n in [
        'en0',
        'eth0',
        'wlan0',
        'utun3',
        'Wi-Fi',
        'tailscale0',
      ]) {
        expect(isVirtualInterfaceName(n), isFalse, reason: n);
      }
    });
  });

  group('classifyInterfaces', () {
    final machine = [
      LocalInterface('en0', [
        InternetAddress('192.168.1.50'),
        InternetAddress('2a02:abcd:1::50'),
        InternetAddress('2a02:abcd:1::51'),
        InternetAddress('fd00::50'),
        InternetAddress('fe80::1c2d'),
      ]),
      LocalInterface('utun4', [
        InternetAddress('100.101.102.103'),
        InternetAddress('fd7a:115c::1'),
      ]),
      LocalInterface('docker0', [InternetAddress('172.17.0.1')]),
      LocalInterface('eth1', [
        InternetAddress('10.8.0.2'),
        InternetAddress('169.254.9.9'),
        InternetAddress('93.184.216.34'),
      ]),
    ];

    test('splits and orders addresses', () {
      final r = classifyInterfaces(machine);
      expect(r.lanIPv4.map((a) => a.address), [
        '192.168.1.50',
        '10.8.0.2',
        '100.101.102.103',
      ]);
      expect(r.publicIPv4.map((a) => a.address), ['93.184.216.34']);
      expect(r.globalIPv6.map((a) => a.address), [
        '2a02:abcd:1::50',
        '2a02:abcd:1::51',
      ]);
    });

    test('the local set includes virtual and link-local addresses', () {
      final r = classifyInterfaces(machine);
      expect(r.isLocal(InternetAddress('172.17.0.1')), isTrue);
      expect(r.isLocal(InternetAddress('127.0.0.1')), isTrue);
      expect(r.isLocal(InternetAddress('::1')), isTrue);
      expect(r.isLocal(InternetAddress('::ffff:192.168.1.50')), isTrue);
      expect(r.isLocal(InternetAddress('169.254.9.9')), isTrue);
      expect(r.isLocal(InternetAddress('192.168.1.51')), isFalse);
      expect(r.isLocal(InternetAddress('8.8.8.8')), isFalse);
    });

    test('virtual interfaces are never advertised', () {
      final r = classifyInterfaces(machine);
      expect(r.lanIPv4.map((a) => a.address), isNot(contains('172.17.0.1')));
    });

    test('duplicate addresses across interfaces appear once', () {
      final r = classifyInterfaces([
        LocalInterface('en0', [InternetAddress('192.168.1.5')]),
        LocalInterface('en1', [InternetAddress('192.168.1.5')]),
      ]);
      expect(r.lanIPv4, hasLength(1));
    });

    test('scanLocalAddresses survives a failing lister', () async {
      final r = await scanLocalAddresses(() async => throw const OSError('x'));
      expect(r.lanIPv4, isEmpty);
      expect(r.isLocal(InternetAddress.loopbackIPv4), isTrue);
    });

    test('the real machine scan does not throw', () async {
      final r = await scanLocalAddresses();
      expect(r.all, contains(addressKey(InternetAddress.loopbackIPv4)));
    });
  });
}
