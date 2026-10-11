import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/net/connect_target.dart';
import 'package:thelxis/net/net_address.dart';

const _id = 'K7M2P9XQ4TAB8HDE';

void main() {
  group('NetAddress.parse', () {
    test('host, host:port, IPv4', () {
      expect(NetAddress.parse('example.com'), NetAddress('example.com', 47100));
      expect(NetAddress.parse('Example.COM:8080'), NetAddress('example.com', 8080));
      expect(NetAddress.parse('192.168.1.5'), NetAddress('192.168.1.5', 47100));
      expect(NetAddress.parse('192.168.1.5:47100')!.hostPort, '192.168.1.5:47100');
    });

    test('IPv6 in brackets, with and without port; bare IPv6', () {
      expect(NetAddress.parse('[2001:db8::1]:47100'), NetAddress('2001:db8::1', 47100));
      expect(NetAddress.parse('[2001:db8::1]'), NetAddress('2001:db8::1', 47100));
      expect(NetAddress.parse('[::1]:9')!.hostPort, '[::1]:9');
      expect(NetAddress.parse('2001:db8::1'), NetAddress('2001:db8::1', 47100));
      expect(NetAddress.parse('[2001:db8::1]:47100')!.urlHost, '[2001:db8::1]');
      expect(NetAddress.parse('[2001:db8::1]:47100')!.signalingUri.toString(), 'ws://[2001:db8::1]:47100/thelxis');
    });

    test('rejects nonsense', () {
      for (final bad in ['', ' ', 'a b', '300.1.1.1', '1.2.3', '1.2.3.4:0', '1.2.3.4:99999', 'host:port', '[::1', '[::1]x', '-bad.com', 'a..b', 'x@y', 'host/path']) {
        expect(NetAddress.parse(bad), isNull, reason: bad);
      }
    });
  });

  group('parseConnectInput', () {
    test('bare address is trust-on-first-use (no ID)', () {
      final t = parseConnectInput('203.0.113.5').target!;
      expect(t.id, isNull);
      expect(t.addresses.single.hostPort, '203.0.113.5:47100');
      expect(parseConnectInput('office.example.com:5000').target!.addresses.single.port, 5000);
      expect(parseConnectInput('[2001:db8::7]:47100').target!.addresses.single.isIPv6, isTrue);
    });

    test('ID@address binds the ID to the address', () {
      final t = parseConnectInput('K7M2-P9XQ-4TAB-8HDE@203.0.113.5:47100').target!;
      expect(t.id, _id);
      expect(t.addresses.single.hostPort, '203.0.113.5:47100');
      final v6 = parseConnectInput('$_id@[2001:db8::1]:47100').target!;
      expect(v6.addresses.single.hostPort, '[2001:db8::1]:47100');
      final multi = parseConnectInput('$_id@1.2.3.4,[2001:db8::1]:5000').target!;
      expect(multi.addresses.map((a) => a.hostPort), ['1.2.3.4:47100', '[2001:db8::1]:5000']);
    });

    test('ID parsing is tolerant: case, dashes, spaces, I/L/O', () {
      for (final s in ['k7m2-p9xq-4tab-8hde', 'K7M2 P9XQ 4TAB 8HDE', 'k7m2p9xq4tab8hde']) {
        expect(parseConnectInput(s).target!.id, _id, reason: s);
      }
      // O->0, I->1, L->1 : "0123456789ABCDEF" typed with letters.
      expect(parseConnectInput('OI23-456789ABCDEF').target!.id, '0123456789ABCDEF');
      expect(parseConnectInput('0L23456789ABCDEF').target!.id, '0123456789ABCDEF');
    });

    test('an ID alone needs resolution through the address book or LAN', () {
      final t = parseConnectInput(_id).target!;
      expect(t.id, _id);
      expect(t.needsResolution, isTrue);
    });

    test('invite link', () {
      final link =
          'thelxis://connect?id=K7M2P9XQ4TAB8HDE&n=Office%20PC&a=203.0.113.5:47100,[2001:db8::1]:47100,192.168.1.23:47100';
      final t = parseConnectInput(link).target!;
      expect(t.id, _id);
      expect(t.name, 'Office PC');
      expect(t.addresses.map((a) => a.hostPort), [
        '203.0.113.5:47100',
        '[2001:db8::1]:47100',
        '192.168.1.23:47100',
      ]);
    });

    test('invite link built by buildInviteLink round-trips', () {
      final link = buildInviteLink(
        id: _id,
        name: 'Zoë & Co ПК',
        addresses: ['203.0.113.5:47100', '[2001:db8::1]:47100'],
      );
      expect(link.startsWith('thelxis://connect?id=$_id&n='), isTrue);
      expect(link, contains('a=203.0.113.5:47100,[2001:db8::1]:47100'));
      final t = parseConnectInput(link).target!;
      expect(t.id, _id);
      expect(t.name, 'Zoë & Co ПК');
      expect(t.addresses, hasLength(2));
    });

    test('invite link without addresses still parses', () {
      final t = parseConnectInput('thelxis://connect?id=$_id').target!;
      expect(t.addresses, isEmpty);
      expect(t.needsResolution, isTrue);
    });

    test('bad inputs give an error message, never a target', () {
      for (final bad in ['', '   ', 'hello world', 'thelxis://connect?id=SHORT', 'thelxis://other?id=$_id', 'BAD@1.2.3.4', '$_id@', '$_id@not a host', 'K7M2P9XQ4TAB8HD']) {
        final r = parseConnectInput(bad);
        expect(r.isOk, isFalse, reason: bad);
        expect(r.error, isNotEmpty, reason: bad);
      }
    });

    test('IDs are not mistaken for hostnames, hostnames are not mistaken for IDs', () {
      expect(parseConnectInput('localhost').target!.id, isNull);
      expect(parseConnectInput('my-server.lan:47100').target!.id, isNull);
    });
  });

  test('ID@address display helper', () {
    expect(buildIdAtAddress(_id, '1.2.3.4:47100'), 'K7M2-P9XQ-4TAB-8HDE@1.2.3.4:47100');
    expect(buildIdAtAddress(_id, null), 'K7M2-P9XQ-4TAB-8HDE');
  });
}
