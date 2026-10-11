import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/net/connectivity/gateway.dart';

List<String> _a(List<InternetAddress> l) => [for (final x in l) x.address];

void main() {
  test('macOS route -n get default', () {
    const out = '''
   route to: default
destination: default
       mask: default
    gateway: 192.168.178.1
  interface: en0
      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
''';
    expect(_a(parseMacDefaultGateway(out)), ['192.168.178.1']);
    expect(parseMacDefaultGateway('gateway: fe80::1%en0'), isEmpty);
    expect(parseMacDefaultGateway(''), isEmpty);
  });

  test('Linux ip route show default', () {
    const out = '''
default via 192.168.1.254 dev wlan0 proto dhcp metric 600
default via 10.0.2.2 dev eth0 proto dhcp metric 100
default via fe80::1 dev eth0 proto ra metric 1024
''';
    expect(_a(parseLinuxDefaultGateways(out)), ['192.168.1.254', '10.0.2.2']);
    expect(
      parseLinuxDefaultGateways('10.0.0.0/24 dev eth0 scope link'),
      isEmpty,
    );
  });

  test('/proc/net/route (little-endian hex)', () {
    const out = '''
Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT
wlan0\t00000000\t0101A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0
wlan0\t0001A8C0\t00000000\t0001\t0\t0\t600\t00FFFFFF\t0\t0\t0
''';
    expect(_a(parseProcNetRoute(out)), ['192.168.1.1']);
  });

  test('Windows route print 0.0.0.0, lowest metric first', () {
    const out = r'''
===========================================================================
Interface List
 12...00 15 5d 01 02 03 ......Hyper-V Virtual Ethernet Adapter
===========================================================================

IPv4 Route Table
===========================================================================
Active Routes:
Network Destination        Netmask          Gateway       Interface  Metric
          0.0.0.0          0.0.0.0     192.168.0.254   192.168.0.77     35
          0.0.0.0          0.0.0.0      192.168.1.1     192.168.1.50     25
          0.0.0.0          0.0.0.0         On-link      10.0.0.2    281
===========================================================================
Persistent Routes:
  None
''';
    expect(_a(parseWindowsDefaultGateways(out)), [
      '192.168.1.1',
      '192.168.0.254',
    ]);
  });

  test('guessGateways returns .1 of private /24s only', () {
    final guesses = guessGateways([
      InternetAddress('192.168.1.50'),
      InternetAddress('10.4.5.6'),
      InternetAddress('100.101.102.103'), // shared space: not guessed
      InternetAddress('192.168.1.1'), // we ARE .1
      InternetAddress('8.8.8.8'),
    ]);
    expect(_a(guesses), ['192.168.1.1', '10.4.5.1']);
  });

  group('readOsDefaultGateways', () {
    test('macOS runs /sbin/route', () async {
      final calls = <String>[];
      final r = await readOsDefaultGateways(
        platform: 'macos',
        run: (exe, args) async {
          calls.add('$exe ${args.join(' ')}');
          return '    gateway: 192.168.5.1\n';
        },
      );
      expect(calls, ['/sbin/route -n get default']);
      expect(_a(r), ['192.168.5.1']);
    });

    test('Windows runs route print', () async {
      final calls = <String>[];
      await readOsDefaultGateways(
        platform: 'windows',
        run: (exe, args) async {
          calls.add('$exe ${args.join(' ')}');
          return null;
        },
      );
      expect(calls, ['route print 0.0.0.0']);
    });

    test('Linux falls back to /proc/net/route when ip is missing', () async {
      final r = await readOsDefaultGateways(
        platform: 'linux',
        run: (exe, args) async => null,
        readFile: (path) async => 'h\nwlan0\t00000000\t0100A8C0\t0003\n',
      );
      expect(_a(r), ['192.168.0.1']);
    });

    test('failures yield an empty list', () async {
      expect(
        await readOsDefaultGateways(
          platform: 'macos',
          run: (_, _) async => throw StateError('x'),
        ),
        isEmpty,
      );
      expect(
        await readOsDefaultGateways(
          platform: 'fuchsia',
          run: (_, _) async => 'x',
        ),
        isEmpty,
      );
    });
  });

  test('runCommand returns stdout and null for missing programs', () async {
    expect(await runCommand('/definitely/not/here', const []), isNull);
    if (!Platform.isWindows) {
      expect((await runCommand('/bin/echo', ['hi']))?.trim(), 'hi');
    }
  });
}
