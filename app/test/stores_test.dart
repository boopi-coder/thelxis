import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/core/address_book.dart';
import 'package:thelxis/core/settings.dart';
import 'package:thelxis/core/trusted_devices.dart';
import 'package:thelxis/net/peer_identity.dart';
import 'package:thelxis/protocol/models.dart';
import 'package:thelxis/session/session_history.dart';

const _idA = 'K7M2P9XQ4TAB8HDE';
const _idB = '0123456789ABCDEF';

PeerIdentity _peer(String id, {String name = 'Office PC', List<String> addresses = const []}) =>
    PeerIdentity(key: 'key-$id', id: id, name: name, os: 'windows', addresses: addresses);

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  group('AddressBook', () {
    test('upsert remembers the peer, newest address first, and persists', () async {
      final book = AddressBook(prefs);
      await book.upsertPeer(_peer(_idA, addresses: ['10.0.0.2:47100']), reachedAt: '203.0.113.5:47100', connected: true);
      await book.upsertPeer(_peer(_idA, name: 'Renamed'), reachedAt: '198.51.100.9:47100');
      final e = book.byId(_idA)!;
      expect(e.name, 'Renamed');
      expect(e.addresses, ['198.51.100.9:47100', '203.0.113.5:47100', '10.0.0.2:47100']);
      expect(e.lastConnected, isNotNull);
      expect(e.key, 'key-$_idA');

      final reloaded = AddressBook(prefs);
      expect(reloaded.entries, hasLength(1));
      expect(reloaded.byId(_idA)!.addresses, e.addresses);
    });

    test('ordering: favorites first, then recently used; recents only list connected entries', () async {
      final book = AddressBook(prefs);
      await book.upsertPeer(_peer(_idA, name: 'A'), connected: true);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await book.upsertPeer(_peer(_idB, name: 'B'), connected: true);
      expect(book.entries.map((e) => e.name), ['B', 'A']);
      await book.update(_idA, favorite: true);
      expect(book.entries.map((e) => e.name), ['A', 'B']);
      expect(book.recents().map((e) => e.name), ['B', 'A']);
      await book.addManual(id: 'ZZZZZZZZZZZZZZZZ', name: 'Manual');
      expect(book.recents().map((e) => e.name), isNot(contains('Manual')));
    });

    test('edit alias, tags, notes; alias wins as display name', () async {
      final book = AddressBook(prefs);
      await book.upsertPeer(_peer(_idA));
      await book.update(_idA, alias: ' Reception ', tags: [' finance ', '', 'pc'], notes: 'n', addresses: ['1.2.3.4:47100']);
      final e = book.byId(_idA)!;
      expect(e.displayName, 'Reception');
      expect(e.tags, ['finance', 'pc']);
      expect(e.notes, 'n');
      expect(e.addresses, ['1.2.3.4:47100']);
      await book.remove(_idA);
      expect(book.byId(_idA), isNull);
    });

    test('export then import into a fresh book merges and round-trips', () async {
      final a = AddressBook(prefs);
      await a.upsertPeer(_peer(_idA, addresses: ['1.1.1.1:47100']), connected: true);
      await a.update(_idA, alias: 'Boss PC', tags: ['vip'], favorite: true, notes: 'be nice');
      final json = a.exportJson();
      expect(jsonDecode(json)['format'], 'thelxis-address-book');

      SharedPreferences.setMockInitialValues({});
      final b = AddressBook(await SharedPreferences.getInstance());
      await b.upsertPeer(_peer(_idA, addresses: ['2.2.2.2:47100']));
      final n = await b.importJson(json);
      expect(n, 1);
      final e = b.byId(_idA)!;
      expect(e.alias, 'Boss PC');
      expect(e.favorite, isTrue);
      expect(e.tags, ['vip']);
      expect(e.addresses, containsAll(['1.1.1.1:47100', '2.2.2.2:47100']));
    });

    test('importing garbage throws FormatException and changes nothing', () async {
      final book = AddressBook(prefs);
      await expectLater(book.importJson('not json'), throwsA(isA<FormatException>()));
      await expectLater(book.importJson('{"format":"other"}'), throwsA(isA<FormatException>()));
      expect(book.entries, isEmpty);
    });

    test('a corrupt store is treated as empty', () async {
      SharedPreferences.setMockInitialValues({'address_book_v2': '{{{'});
      final book = AddressBook(await SharedPreferences.getInstance());
      expect(book.entries, isEmpty);
    });
  });

  group('TrustedDevices', () {
    test('add, query, update permissions, revoke, persist', () async {
      final t = TrustedDevices(prefs);
      expect(t.isTrusted('k'), isFalse);
      await t.add(key: 'k', id: _idA, name: 'Alice', permissions: const Permissions(clipboard: false));
      expect(t.isTrusted('k'), isTrue);
      expect(t.permissionsFor('k'), const Permissions(clipboard: false));
      await t.updatePermissions('k', const Permissions(control: false));
      expect(TrustedDevices(prefs).permissionsFor('k'), const Permissions(control: false));
      await t.revoke('k');
      expect(TrustedDevices(prefs).isTrusted('k'), isFalse);
    });

    test('a corrupt store fails closed: nobody is trusted', () async {
      SharedPreferences.setMockInitialValues({'trusted_devices_v2': 'oops'});
      expect(TrustedDevices(await SharedPreferences.getInstance()).devices, isEmpty);
    });
  });

  group('AppSettings', () {
    test('defaults are safe and match the spec', () {
      final s = AppSettings(prefs, defaultDeviceName: 'My Mac');
      expect(s.deviceName, 'My Mac');
      expect(s.allowIncoming, isTrue);
      expect(s.upnp, isTrue);
      expect(s.publicStun, isTrue, reason: 'public STUN is on by default since 0.1.1');
      expect(s.manualForwardingEnabled, isFalse);
      expect(s.manualForwarding, isNull);
      expect(s.requireApproval, isFalse);
      expect(s.lanDiscovery, isTrue);
      expect(s.themeMode, ThemeMode.system);
      expect(s.hasPermanentPassword, isFalse);
      expect(s.defaultPermissions, const Permissions());
    });

    test('public STUN is on for existing installs: the 0.1.0 key is ignored', () async {
      SharedPreferences.setMockInitialValues({'public_stun': false});
      final old = await SharedPreferences.getInstance();
      final s = AppSettings(old, defaultDeviceName: 'x');
      expect(s.publicStun, isTrue);
      await s.setPublicStun(false);
      expect(AppSettings(old, defaultDeviceName: 'x').publicStun, isFalse, reason: 'the new choice persists');
      expect(old.getBool('public_stun_v2'), isFalse);
    });

    test('manual forwarding: defaults, persistence, and validation', () async {
      final s = AppSettings(prefs, defaultDeviceName: 'x');
      expect((s.manualSignalingPort, s.manualTurnUdpPort, s.manualTurnTcpPort), (47100, 47100, 47101));
      expect(s.manualForwarding, isNull);

      await s.setManualForwardingEnabled(true);
      await s.setManualForwardingDetails(host: ' home.example.org ', signalingTcp: 50000, turnUdp: 50001, turnTcp: 50002);
      var f = AppSettings(prefs, defaultDeviceName: 'x').manualForwarding!;
      expect((f.externalHost, f.signalingTcp, f.turnUdp, f.turnTcp), ('home.example.org', 50000, 50001, 50002));

      // Invalid input leaves the previous values alone.
      await s.setManualForwardingDetails(host: 'bad host!', signalingTcp: 0, turnUdp: 70000, turnTcp: -1);
      f = s.manualForwarding!;
      expect((f.externalHost, f.signalingTcp, f.turnUdp, f.turnTcp), ('home.example.org', 50000, 50001, 50002));

      // An empty host means "use the router's address".
      await s.setManualForwardingDetails(host: '');
      expect(s.manualForwarding!.externalHost, isNull);
      await s.setManualForwardingEnabled(false);
      expect(s.manualForwarding, isNull);
    });

    test('forward host validation accepts IPs and DNS names only', () {
      for (final ok in ['203.0.113.7', 'example.org', 'my-router.dyndns.org', '2001:db8::1', 'a']) {
        expect(AppSettings.isValidForwardHost(ok), isTrue, reason: ok);
      }
      for (final bad in ['', '999.1.1.1', 'bad host', 'a..b', '-x.org', 'x.org:80', 'http://x.org', 'a_b.org']) {
        expect(AppSettings.isValidForwardHost(bad), isFalse, reason: bad);
      }
      expect([0, 1, 65535, 65536, null].map(AppSettings.isValidPort), [false, true, true, false, false]);
    });

    test('values persist and notify', () async {
      final s = AppSettings(prefs, defaultDeviceName: 'x');
      var notified = 0;
      s.addListener(() => notified++);
      await s.setDeviceName('  Office  ');
      await s.setPublicStun(false);
      await s.setThemeMode(ThemeMode.light);
      await s.setDefaultPermissions(const Permissions(control: false));
      await s.setUnattendedKey([1, 2, 3, 4]);
      expect(notified, 5);
      final again = AppSettings(prefs, defaultDeviceName: 'x');
      expect(again.deviceName, 'Office');
      expect(again.publicStun, isFalse);
      expect(again.themeMode, ThemeMode.light);
      expect(again.defaultPermissions.control, isFalse);
      expect(again.unattendedKey, [1, 2, 3, 4]);
      await again.setUnattendedKey(null);
      expect(again.hasPermanentPassword, isFalse);
    });
  });

  test('SessionHistory keeps the newest 50 and persists', () async {
    final s = AppSettings(prefs, defaultDeviceName: 'x');
    final h = SessionHistory(s);
    for (var i = 0; i < 55; i++) {
      await h.add(SessionRecord(
        sid: 's$i',
        incoming: i.isEven,
        peerName: 'P$i',
        peerId: _idA,
        peerOs: 'linux',
        startedAt: DateTime(2030, 1, 1),
        durationSeconds: i,
        path: 'LAN',
        reason: 'user',
      ));
    }
    expect(h.records, hasLength(50));
    expect(h.records.first.sid, 's54');
    final reloaded = SessionHistory(AppSettings(prefs, defaultDeviceName: 'x'));
    expect(reloaded.records, hasLength(50));
    expect(reloaded.records.first.durationSeconds, 54);
    await reloaded.clear();
    expect(SessionHistory(AppSettings(prefs, defaultDeviceName: 'x')).records, isEmpty);
  });
}
