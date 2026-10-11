import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/core/address_book.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/log.dart';
import 'package:thelxis/core/settings.dart';
import 'package:thelxis/l10n/strings.dart';
import 'package:thelxis/net/connect_target.dart';
import 'package:thelxis/net/discovery.dart';
import 'package:thelxis/net/net_address.dart';
import 'package:thelxis/net/peer_identity.dart';
import 'package:thelxis/session/link_stats.dart';
import 'package:thelxis/session/session_base.dart';

Future<Identity> _id(int fill) => Identity.fromSeed(List<int>.generate(32, (i) => (i * 3 + fill) & 0xff));

const _info = LocalPeerInfo(name: 'Office GW', os: 'windows', app: '0.2.0');

void main() {
  Logger.sink = (_, _) {};

  group('discovery: gateway announcement (PROTOCOL.md section 7)', () {
    late Identity gw;
    setUp(() async => gw = await _id(1));

    test('a plain device\'s reply has no gateway fields; a gateway\'s carries both', () {
      final plain = jsonDecode(buildHere(identity: gw, info: _info, port: 47100)) as Map;
      expect(plain.containsKey('gateway'), isFalse);
      expect(plain.containsKey('gw_addresses'), isFalse);

      final announced = jsonDecode(buildHere(
        identity: gw,
        info: _info,
        port: 47100,
        gatewayAddresses: ['203.0.113.5:47110', '[2001:db8::1]:47100'],
      )) as Map;
      expect(announced['gateway'], isTrue);
      expect(announced['gw_addresses'], ['203.0.113.5:47110', '[2001:db8::1]:47100']);
    });

    test('parseHere reads them, normalised', () {
      final text = buildHere(identity: gw, info: _info, port: 47100, gatewayAddresses: ['203.0.113.5:47110']);
      final p = parseHere(text, '192.168.1.2')!;
      expect(p.gateway, isTrue);
      expect(p.gatewayAddresses, ['203.0.113.5:47110']);
      expect(p.host, '192.168.1.2');

      final plain = parseHere(buildHere(identity: gw, info: _info, port: 47100), '192.168.1.2')!;
      expect(plain.gateway, isFalse);
      expect(plain.gatewayAddresses, isEmpty);
    });

    test('a reply is unauthenticated: junk addresses are dropped, and no good address means no gateway', () {
      Map<String, dynamic> base() => jsonDecode(buildHere(identity: gw, info: _info, port: 47100)) as Map<String, dynamic>;
      final mixed = parseHere(
        jsonEncode({...base(), 'gateway': true, 'gw_addresses': ['not an address', '203.0.113.5:47110', 5, 'x@y', '1.2.3.4:99999']}),
        'h',
      )!;
      expect(mixed.gatewayAddresses, ['203.0.113.5:47110']);
      final none = parseHere(jsonEncode({...base(), 'gateway': true, 'gw_addresses': ['a..b', '', 7, '1.2.3.4:99999']}), 'h')!;
      expect(none.gateway, isFalse);
      final noFlag = parseHere(jsonEncode({...base(), 'gw_addresses': ['203.0.113.5:47110']}), 'h')!;
      expect(noFlag.gateway, isFalse, reason: 'the flag is what announces a gateway');
      final tooMany = parseHere(
        jsonEncode({...base(), 'gateway': true, 'gw_addresses': [for (var i = 1; i < 30; i++) '203.0.113.$i:47100']}),
        'h',
      )!;
      expect(tooMany.gatewayAddresses, hasLength(8));
    });

    test('LanDiscovery lists the gateways it has seen', () async {
      final me = await _id(9);
      final lan = LanDiscovery(identity: me, localInfo: () => _info, signalingPort: () => 0, discoveryPort: 47975);
      addTearDown(lan.dispose);
      lan.debugReply(buildHere(identity: gw, info: _info, port: 47100, gatewayAddresses: ['203.0.113.5:47100']), '10.0.0.2');
      final other = await _id(5);
      lan.debugReply(buildHere(identity: other, info: const LocalPeerInfo(name: 'Plain', os: 'linux', app: '0'), port: 47100), '10.0.0.3');
      expect(lan.peers, hasLength(2));
      expect(lan.gateways.map((g) => g.name), ['Office GW']);
    });

    test('find: a fresh table entry is returned at once; a stale one triggers a scan and waits for a reply', () async {
      final me = await _id(9);
      final lan = LanDiscovery(identity: me, localInfo: () => _info, signalingPort: () => 0, discoveryPort: 47975);
      addTearDown(lan.dispose);
      final text = buildHere(identity: gw, info: _info, port: 47100);

      expect(await lan.find(gw.id, wait: const Duration(milliseconds: 200)), isNull, reason: 'unknown device');

      lan.debugReply(text, '10.0.0.2');
      final sw = Stopwatch()..start();
      expect((await lan.find(gw.id))!.host, '10.0.0.2');
      expect(sw.elapsedMilliseconds, lessThan(100));

      // Nothing within maxAge: an old entry is not trusted; the reply that
      // arrives during the scan is.
      Timer(const Duration(milliseconds: 150), () => lan.debugReply(text, '10.0.0.7'));
      final fresh = await lan.find(gw.id, maxAge: Duration.zero, wait: const Duration(seconds: 2));
      expect(fresh!.host, '10.0.0.7');

      // An old entry and no new reply: not found after the wait.
      expect(await lan.find(gw.id, maxAge: Duration.zero, wait: const Duration(milliseconds: 200)), isNull);
    });
  });

  group('invite links with gateways (PROTOCOL.md section 3)', () {
    const id = 'K7M2P9XQ4TAB8HDE';

    test('g= carries the gateways next to a=', () {
      final t = parseConnectInput('thelxis://connect?id=$id&n=Office%20PC&a=192.168.1.20:47100&g=203.0.113.5:47110,[2001:db8::5]:47100')
          .target!;
      expect(t.id, id);
      expect(t.addresses, [const NetAddress('192.168.1.20', 47100)]);
      expect(t.gateways, [const NetAddress('203.0.113.5', 47110), const NetAddress('2001:db8::5', 47100)]);
    });

    test('built links round trip, and old links without g= still parse', () {
      final link = buildInviteLink(id: id, name: 'Office PC', addresses: ['192.168.1.20:47100'], gateways: ['203.0.113.5:47110']);
      expect(link, contains('&g=203.0.113.5:47110'));
      final back = parseConnectInput(link).target!;
      expect(back.gateways.single, const NetAddress('203.0.113.5', 47110));
      expect(back.addresses.single, const NetAddress('192.168.1.20', 47100));

      expect(buildInviteLink(id: id, name: 'x', addresses: ['1.2.3.4:5']), isNot(contains('g=')));
      expect(parseConnectInput('thelxis://connect?id=$id&a=1.2.3.4').target!.gateways, isEmpty);
    });

    test('junk and duplicates in g= are dropped', () {
      final t = parseConnectInput('thelxis://connect?id=$id&g=a..b,203.0.113.5,203.0.113.5:47100,,x%40y').target!;
      expect(t.gateways, [const NetAddress('203.0.113.5', 47100)]);
    });

    test('the gateway addresses are plain host:port, never a via route by themselves', () {
      final t = parseConnectInput('thelxis://connect?id=$id&g=203.0.113.5:47110').target!;
      expect(t.gateways.single.isViaGateway, isFalse);
      expect(t.gateways.single.viaTarget(id).isViaGateway, isTrue);
    });
  });

  group('address book keeps gateways', () {
    late AddressBook book;
    late SharedPreferences prefs;
    const peer = PeerIdentity(key: 'k', id: 'K7M2P9XQ4TAB8HDE', name: 'Office PC', os: 'windows');

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      book = AddressBook(prefs);
    });

    test('stored separately from the device\'s own addresses, merged, capped, persisted', () async {
      await book.upsertPeer(peer, reachedAt: '192.168.1.20:47100', gateways: ['203.0.113.5:47110']);
      await book.upsertPeer(peer, gateways: ['203.0.113.6:47100', '203.0.113.5:47110']);
      final e = book.byId(peer.id)!;
      expect(e.addresses, ['192.168.1.20:47100']);
      expect(e.gateways, ['203.0.113.6:47100', '203.0.113.5:47110']);
      expect(AddressBook(prefs).byId(peer.id)!.gateways, e.gateways);
      expect(e.toJson()['gateways'], e.gateways);
    });

    test('export and import carry them; entries without gateways omit the field', () async {
      await book.upsertPeer(peer, gateways: ['203.0.113.5:47110']);
      final other = AddressBook((await (() async {
        SharedPreferences.setMockInitialValues({});
        return SharedPreferences.getInstance();
      })()));
      expect(await other.importJson(book.exportJson()), 1);
      expect(other.byId(peer.id)!.gateways, ['203.0.113.5:47110']);

      await book.upsertPeer(const PeerIdentity(key: 'k2', id: '0123456789ABCDEF', name: 'No gw', os: 'linux'));
      expect(book.byId('0123456789ABCDEF')!.toJson().containsKey('gateways'), isFalse);
    });
  });

  group('settings', () {
    test('the office gateway is off by default and persists', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final s = AppSettings(prefs, defaultDeviceName: 'x');
      expect(s.officeGateway, isFalse);
      await s.setOfficeGateway(true);
      expect(AppSettings(prefs, defaultDeviceName: 'x').officeGateway, isTrue);
    });
  });

  group('"Via gateway" path label', () {
    test('label exists in both languages', () {
      expect(const LinkStats(path: LinkPath.gateway).pathLabel, 'Via gateway');
      S.current = S.forLanguage(AppLanguage.russian);
      addTearDown(() => S.current = S.forLanguage(AppLanguage.english));
      expect(const LinkStats(path: LinkPath.gateway).pathLabel, 'Через шлюз');
    });

    List<StatEntry> relayed() => [
          StatEntry('RTCInboundRTPVideoStream_1', 'inbound-rtp', {
            'kind': 'video',
            'bytesReceived': 1,
            'framesDecoded': 1,
            'packetsLost': 0,
            'packetsReceived': 1,
          }),
          StatEntry('T01', 'transport', {'selectedCandidatePairId': 'CP1'}),
          StatEntry('CP1', 'candidate-pair', {
            'state': 'succeeded',
            'nominated': true,
            'localCandidateId': 'L1',
            'remoteCandidateId': 'R1',
          }),
          StatEntry('L1', 'local-candidate', {'candidateType': 'relay', 'address': '203.0.113.5'}),
          StatEntry('R1', 'remote-candidate', {'candidateType': 'host', 'address': '192.168.1.20'}),
        ];

    test('media relayed through the gateway is reported as the gateway, not "via host TURN"', () async {
      for (final viaGateway in [false, true]) {
        final target = ValueNotifier(LinkStats.empty);
        final poller = StatsPoller(
          fetch: () async => relayed(),
          target: target,
          interval: const Duration(milliseconds: 10),
          viaGateway: viaGateway,
        )..start();
        final until = DateTime.now().add(const Duration(seconds: 3));
        while (target.value.path == LinkPath.unknown && DateTime.now().isBefore(until)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        poller.stop();
        expect(target.value.path, viaGateway ? LinkPath.gateway : LinkPath.relay);
      }
    });
  });
}
