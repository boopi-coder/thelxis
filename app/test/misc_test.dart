import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/core/address_book.dart';
import 'package:thelxis/core/base64url.dart';
import 'package:thelxis/core/format.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/system_info.dart';
import 'package:thelxis/core/thelxis_id.dart';
import 'package:thelxis/net/connectivity/connectivity.dart';
import 'package:thelxis/net/discovery.dart';
import 'package:thelxis/net/handshake.dart';
import 'package:thelxis/net/net_address.dart';
import 'package:thelxis/net/peer_identity.dart';
import 'package:thelxis/net/signaling_channel.dart';
import 'package:thelxis/protocol/signaling_messages.dart';
import 'package:thelxis/session/clipboard_sync.dart';
import 'package:thelxis/session/hid.dart';
import 'package:thelxis/session/ice_config.dart';
import 'package:thelxis/session/input_encoder.dart';
import 'package:thelxis/session/quality.dart';
import 'package:thelxis/protocol/models.dart';
import 'package:thelxis/ui/devices/command_palette.dart';
import 'package:thelxis/ui/home/reachability.dart';
import 'package:thelxis/ui/session/connection_level.dart';
import 'package:thelxis/session/link_stats.dart';
import 'package:thelxis/session/session_base.dart';
import 'package:thelxis/ui/session/soft_keyboard.dart';
import 'package:thelxis/ui/session/special_keys.dart';
import 'package:thelxis/ui/widgets/common.dart';

void main() {
  group('Thelxis ID', () {
    test('format and tolerant parse', () {
      expect(formatThelxisId('K7M2P9XQ4TAB8HDE'), 'K7M2-P9XQ-4TAB-8HDE');
      expect(formatThelxisId(null), '—');
      expect(parseThelxisId(' k7m2-p9xq 4tab-8hde '), 'K7M2P9XQ4TAB8HDE');
      expect(parseThelxisId('short'), isNull);
      expect(parseThelxisId('K7M2P9XQ4TAB8HDU'), isNull, reason: 'U is not in the alphabet');
      expect(parseThelxisId(null), isNull);
    });

    test('Crockford encoding of known byte strings', () {
      expect(crockfordEncode([0, 0, 0, 0, 0]), '00000000');
      expect(crockfordEncode([255, 255, 255, 255, 255]), 'ZZZZZZZZ');
      expect(crockfordEncode([1, 2, 3, 4, 5]), '04106105');
    });

    test('an identity derives its ID from its key and is stable across restarts', () async {
      final dir = await Directory.systemTemp.createTemp('thelxis-id-test');
      addTearDown(() => dir.delete(recursive: true));
      final a = await Identity.loadOrCreate(dir: dir);
      final b = await Identity.loadOrCreate(dir: dir);
      expect(a.publicKeyB64, b.publicKeyB64);
      expect(a.id, b.id);
      expect(a.id, thelxisIdFromPublicKey(a.publicKey));
      expect(a.id, hasLength(16));
      final json = jsonDecode(await File('${dir.path}/identity.json').readAsString()) as Map;
      expect(json['public_key'], a.publicKeyB64);
      if (!Platform.isWindows) {
        final mode = (await File('${dir.path}/identity.json').stat()).mode & 0x1ff;
        expect(mode, 384, reason: 'identity.json must be chmod 600');
      }
    });

    test('a corrupt identity file is replaced by a fresh key', () async {
      final dir = await Directory.systemTemp.createTemp('thelxis-id-bad');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/identity.json').writeAsString('garbage');
      final id = await Identity.loadOrCreate(dir: dir);
      expect(id.publicKey, hasLength(32));
    });

    test('signatures verify only with the signer\'s key', () async {
      final a = await Identity.fromSeed(List<int>.filled(32, 1));
      final b = await Identity.fromSeed(List<int>.filled(32, 2));
      final sig = await a.signString('hello');
      expect(await Identity.verify(message: utf8.encode('hello'), signature: sig, publicKey: a.publicKey), isTrue);
      expect(await Identity.verify(message: utf8.encode('hellO'), signature: sig, publicKey: a.publicKey), isFalse);
      expect(await Identity.verify(message: utf8.encode('hello'), signature: sig, publicKey: b.publicKey), isFalse);
    });
  });

  group('handshake transcripts (PROTOCOL.md 4.1, 4.2)', () {
    test('exact strings', () {
      expect(
        listenerHandshakePayload(dialerNonce: 'nD', listenerNonce: 'nL', dialerKey: 'KD'),
        'thelxis-hs-v2|listener|nD|nL|KD',
      );
      expect(
        dialerHandshakePayload(dialerNonce: 'nD', listenerNonce: 'nL', listenerKey: 'KL'),
        'thelxis-hs-v2|dialer|nD|nL|KL',
      );
      expect(
        sdpPayload(dialerNonce: 'nD', listenerNonce: 'nL', type: 'offer', sdp: 'v=0'),
        'thelxis-sdp-v2|nD|nL|offer|v=0',
      );
    });

    test('signatures verify against the exact transcript and nothing else', () async {
      final l = await Identity.fromSeed(List<int>.filled(32, 7));
      final d = await Identity.fromSeed(List<int>.filled(32, 8));
      final sig = await signPayload(
        l,
        listenerHandshakePayload(dialerNonce: 'nD', listenerNonce: 'nL', dialerKey: d.publicKeyB64),
      );
      Future<bool> check({String nD = 'nD', String nL = 'nL', String? dk}) => verifyPayload(
            peerKey: l.publicKeyB64,
            signature: sig,
            payload: listenerHandshakePayload(dialerNonce: nD, listenerNonce: nL, dialerKey: dk ?? d.publicKeyB64),
          );
      expect(await check(), isTrue);
      expect(await check(nD: 'x'), isFalse, reason: 'bound to the dialer nonce');
      expect(await check(nL: 'x'), isFalse, reason: 'bound to the listener nonce');
      expect(await check(dk: l.publicKeyB64), isFalse, reason: 'bound to the dialer key');
      expect(await verifyPayload(peerKey: 'not-a-key', signature: sig, payload: 'x'), isFalse);
      expect(await verifyPayload(peerKey: l.publicKeyB64, signature: 'short', payload: 'x'), isFalse);
    });

    test('nonces are 32 random bytes in base64url', () {
      final n = generateNonce();
      expect(b64uDecode(n), hasLength(32));
      expect(n.contains('='), isFalse);
      expect(generateNonce(), isNot(n));
    });
  });

  group('LAN discovery messages (PROTOCOL.md 7)', () {
    test('discover and here round-trip; the ID must match the key', () async {
      final id = await Identity.fromSeed(List<int>.filled(32, 3));
      expect(jsonDecode(buildDiscover()), {'t': 'discover', 'v': 2});
      expect(isDiscover(buildDiscover()), isTrue);
      expect(isDiscover('{"t":"here"}'), isFalse);
      expect(isDiscover('garbage'), isFalse);

      final here = buildHere(identity: id, info: const LocalPeerInfo(name: 'Office PC', os: 'windows', app: '0.1.0'), port: 47100);
      final decoded = jsonDecode(here) as Map;
      expect(decoded['id'], id.id);
      expect(decoded['key'], id.publicKeyB64);
      expect(decoded['port'], 47100);

      final peer = parseHere(here, '192.168.1.40')!;
      expect(peer.id, id.id);
      expect(peer.name, 'Office PC');
      expect(peer.address, '192.168.1.40:47100');

      final forged = jsonEncode({...decoded, 'id': '0123456789ABCDEF'});
      expect(parseHere(forged, '192.168.1.40'), isNull, reason: 'a spoofed ID label is rejected');
      expect(parseHere('{"t":"here","key":"x","port":1}', 'h'), isNull);
      expect(parseHere('nope', 'h'), isNull);
      expect(parseHere(jsonEncode({...decoded, 'port': 0}), 'h'), isNull);
    });
  });

  group('ICE configuration (PROTOCOL.md 4.3)', () {
    const turn = TurnInfo(username: 'u', credential: 'c', udpPort: 47100, tcpPort: 47101);

    test('dialer uses the listener\'s embedded STUN/TURN via the host it connected to', () {
      final c = buildRtcConfiguration(role: SignalingRole.dialer, turn: turn, turnHost: NetAddress('203.0.113.5', 47100));
      expect(c['bundlePolicy'], 'max-bundle');
      final servers = c['iceServers'] as List;
      expect(servers, hasLength(2));
      expect(servers[0]['urls'], ['stun:203.0.113.5:47100']);
      expect(servers[1]['urls'], ['turn:203.0.113.5:47100?transport=udp', 'turn:203.0.113.5:47101?transport=tcp']);
      expect(servers[1]['username'], 'u');
      expect(servers[1]['credential'], 'c');
    });

    test('IPv6 hosts are bracketed', () {
      final c = buildRtcConfiguration(role: SignalingRole.dialer, turn: turn, turnHost: NetAddress('2001:db8::1', 47100));
      final servers = c['iceServers'] as List;
      expect(servers[0]['urls'], ['stun:[2001:db8::1]:47100']);
      expect((servers[1]['urls'] as List).first, 'turn:[2001:db8::1]:47100?transport=udp');
    });

    test('the listener uses no ICE servers', () {
      final c = buildRtcConfiguration(role: SignalingRole.listener, turn: turn, turnHost: NetAddress('1.2.3.4', 1));
      expect(c['iceServers'], isEmpty);
    });

    test('public STUN (both servers) is added for both roles unless switched off', () {
      expect(buildRtcConfiguration(role: SignalingRole.listener)['iceServers'], isEmpty);
      final on = buildRtcConfiguration(role: SignalingRole.listener, publicStun: true)['iceServers'] as List;
      expect(on.single['urls'], PublicStun.urls);
      expect(PublicStun.urls, ['stun:stun.l.google.com:19302', 'stun:stun.cloudflare.com:3478']);
      final both = buildRtcConfiguration(role: SignalingRole.dialer, turn: turn, turnHost: NetAddress('1.2.3.4', 1), publicStun: true)['iceServers'] as List;
      expect(both, hasLength(3));
      expect(both.last['urls'], PublicStun.urls);
      expect(buildRtcConfiguration(role: SignalingRole.dialer, turn: turn, turnHost: NetAddress('1.2.3.4', 1))['iceServers'], hasLength(2));
    });

    test('no TURN grant means no relay servers', () {
      expect(buildRtcConfiguration(role: SignalingRole.dialer, turnHost: NetAddress('1.2.3.4', 1))['iceServers'], isEmpty);
    });
  });

  group('quality presets (PROTOCOL.md 6.2)', () {
    test('values match the table', () {
      final speed = qualityProfileFor(QualityPreset.speed);
      expect((speed.maxFramerate, speed.maxBitrate, speed.degradation), (30, 2500000, 'maintain-framerate'));
      final balanced = qualityProfileFor(QualityPreset.balanced);
      expect((balanced.maxFramerate, balanced.maxBitrate, balanced.degradation), (30, 6000000, 'balanced'));
      final quality = qualityProfileFor(QualityPreset.quality);
      expect(quality.maxFramerate, 60);
      expect(quality.maxBitrate, QualityProfile.uncappedBitrate);
      expect(quality.degradation, 'maintain-resolution');
      final auto = qualityProfileFor(QualityPreset.auto);
      expect(auto.maxBitrate, QualityProfile.uncappedBitrate);
      expect(auto.degradation, 'balanced');
    });
  });

  group('clipboard sync', () {
    test('local changes are sent once, remote text is not echoed back', () async {
      var clip = 'initial';
      final sent = <String>[];
      final sync = ClipboardSync(
        onLocalChange: sent.add,
        readClipboard: () async => clip,
        writeClipboard: (t) async => clip = t,
      );
      await sync.start();
      addTearDown(sync.dispose);
      await sync.poll();
      expect(sent, isEmpty, reason: 'baseline is not sent');

      clip = 'copied locally';
      await sync.poll();
      await sync.poll();
      expect(sent, ['copied locally']);

      await sync.applyRemote('from the other side');
      expect(clip, 'from the other side');
      await sync.poll();
      expect(sent, ['copied locally'], reason: 'no echo of remote text');

      clip = 'x' * (kMaxClipboardSendBytes + 1);
      await sync.poll();
      expect(sent, hasLength(1), reason: 'oversized clipboards are skipped');
    });

    test('a read that was in flight when the peer\'s text arrived is not sent back', () async {
      var clip = 'baseline';
      final sent = <String>[];
      Completer<void>? gate;
      final sync = ClipboardSync(
        onLocalChange: sent.add,
        readClipboard: () {
          final snapshot = clip; // what the platform answers: the value at call time
          final g = gate;
          return g == null ? Future.value(snapshot) : g.future.then((_) => snapshot);
        },
        writeClipboard: (t) async => clip = t,
      );
      await sync.start();
      addTearDown(sync.dispose);
      clip = 'copied here';
      await sync.poll();
      expect(sent, ['copied here']);

      gate = Completer<void>();
      final stale = sync.poll(); // reads 'copied here' ...
      await sync.applyRemote('copied there'); // ... while the peer's text lands
      gate.complete();
      await stale;
      gate = null;
      await sync.poll();
      expect(sent, ['copied here'], reason: 'the old text must not overwrite the peer\'s newer copy');
      expect(clip, 'copied there');
    });

    test('a poll during the write of the peer\'s text does not mistake the old clipboard for a copy', () async {
      var clip = 'baseline';
      final sent = <String>[];
      final writeGate = Completer<void>();
      final sync = ClipboardSync(
        onLocalChange: sent.add,
        readClipboard: () async => clip,
        writeClipboard: (t) async {
          await writeGate.future;
          clip = t;
        },
      );
      await sync.start();
      addTearDown(sync.dispose);
      clip = 'copied here';
      await sync.poll();
      sent.clear();

      final applying = sync.applyRemote('copied there');
      await sync.poll(); // the platform still holds 'copied here'
      expect(sent, isEmpty);
      writeGate.complete();
      await applying;
      await sync.poll();
      expect(sent, isEmpty);
    });

    test('stopping while the baseline is being read leaves no timer running', () async {
      final gate = Completer<String?>();
      final sync = ClipboardSync(
        onLocalChange: (_) {},
        readClipboard: () => gate.future,
        writeClipboard: (_) async {},
      );
      final starting = sync.start();
      await sync.start(); // a second start while the first waits does nothing
      sync.stop();
      gate.complete('x');
      await starting;
      expect(sync.running, isFalse);
    });

    test('oversized remote text is ignored', () async {
      var clip = '';
      final sync = ClipboardSync(onLocalChange: (_) {}, readClipboard: () async => clip, writeClipboard: (t) async => clip = t);
      await sync.applyRemote('y' * (kMaxClipboardBytes + 1));
      expect(clip, '');
    });
  });

  group('soft keyboard diff', () {
    test('typing, backspace on an empty field, multi-char commits', () {
      expect(diffSoftKeyboard(kSoftKeyboardSentinel, '${kSoftKeyboardSentinel}a').text, 'a');
      expect(diffSoftKeyboard(kSoftKeyboardSentinel, '${kSoftKeyboardSentinel}hello ').text, 'hello ');
      final bs = diffSoftKeyboard(kSoftKeyboardSentinel, '');
      expect((bs.backspaces, bs.text), (1, ''));
      expect(diffSoftKeyboard(kSoftKeyboardSentinel, 'x$kSoftKeyboardSentinel').text, 'x');
      expect(diffSoftKeyboard('abc', 'ab').backspaces, 1);
      final replace = diffSoftKeyboard('abc', 'abXY');
      expect((replace.backspaces, replace.text), (1, 'XY'));
    });
  });

  group('special keys', () {
    List<String> run(String os, String label) {
      final out = <String>[];
      final enc = InputEncoder((m) {
        final j = m.toJson();
        out.add('${j['t']}${j['c'] ?? j['a'] ?? ''}');
      });
      specialKeysFor(os).firstWhere((k) => k.label == label).run(enc);
      enc.dispose();
      return out;
    }

    test('Ctrl+Alt+Del is a special action, not a key chord', () {
      expect(run('windows', 'Ctrl + Alt + Del'), ['spctrl_alt_del']);
    });

    test('Alt+Tab is a kd/ku chord with correct nesting', () {
      expect(run('windows', 'Alt + Tab'), ['kd${Hid.altLeft}', 'kd${Hid.tab}', 'ku${Hid.tab}', 'ku${Hid.altLeft}']);
    });

    test('Cmd+Tab on a Mac', () {
      expect(run('macos', 'Cmd + Tab'), ['kd${Hid.metaLeft}', 'kd${Hid.tab}', 'ku${Hid.tab}', 'ku${Hid.metaLeft}']);
    });

    test('Task Manager chord holds Ctrl+Shift', () {
      expect(run('windows', 'Task Manager'), [
        'kd${Hid.controlLeft}',
        'kd${Hid.shiftLeft}',
        'kd${Hid.escape}',
        'ku${Hid.escape}',
        'ku${Hid.shiftLeft}',
        'ku${Hid.controlLeft}',
      ]);
    });

    test('Android targets get system actions', () {
      expect(specialKeysFor('android').map((k) => k.label), containsAll(['Back', 'Home', 'Recent apps']));
      expect(run('android', 'Home'), ['sphome']);
    });

    test('HID helpers', () {
      expect(Hid.f(1), 0x7003A);
      expect(Hid.f(12), 0x70045);
      expect(Hid.keyA, 0x70004);
    });
  });

  group('connection level', () {
    test('thresholds', () {
      expect(connectionLevel(SessionPhase.active, const LinkStats(rttMs: 20, lossPercent: 0)), ConnectionLevel.good);
      expect(connectionLevel(SessionPhase.active, const LinkStats(rttMs: 200)), ConnectionLevel.degraded);
      expect(connectionLevel(SessionPhase.active, const LinkStats(rttMs: 20, lossPercent: 3)), ConnectionLevel.degraded);
      expect(connectionLevel(SessionPhase.active, const LinkStats(rttMs: 900)), ConnectionLevel.bad);
      expect(connectionLevel(SessionPhase.reconnecting, const LinkStats()), ConnectionLevel.bad);
      expect(connectionLevel(SessionPhase.connecting, const LinkStats()), ConnectionLevel.degraded);
    });

    test('summary text', () {
      expect(connectionSummary(const LinkStats(rttMs: 23.6, path: LinkPath.lan)), '24 ms · LAN');
      expect(connectionSummary(const LinkStats()), 'Connecting');
    });
  });

  group('reachability summary', () {
    test('states', () {
      expect(summarizeReachability(allowIncoming: false, report: const ReachabilityReport()).label, 'Not accepting');
      expect(summarizeReachability(allowIncoming: true, report: const ReachabilityReport()).label, 'Listener unavailable');
      expect(summarizeReachability(allowIncoming: true, report: const ReachabilityReport(listening: true)).label, 'LAN only');
      final cg = summarizeReachability(allowIncoming: true, report: const ReachabilityReport(listening: true, cgnat: true));
      expect(cg.detail, contains('CGNAT'));
      final v6 = summarizeReachability(allowIncoming: true, report: const ReachabilityReport(listening: true, globalIPv6: ['2001:db8::1']));
      expect((v6.label, v6.tone), ('Reachable from internet', PillTone.good));
      final v4 = summarizeReachability(
        allowIncoming: true,
        report: const ReachabilityReport(
          listening: true,
          externalIsPublic: true,
          mappings: [PortMapping(protocol: MappingProtocol.tcp, internalPort: 47100, externalPort: 47100, method: MappingMethod.upnp)],
        ),
      );
      expect(v4.label, 'Reachable from internet');
    });
  });

  group('command palette', () {
    final entries = [
      AddressBookEntry(id: 'K7M2P9XQ4TAB8HDE', name: 'Office PC', os: 'windows', tags: ['finance']),
      AddressBookEntry(id: '0123456789ABCDEF', name: 'Home Mac', os: 'macos', alias: 'Kitchen'),
    ];
    final peers = [
      DiscoveredPeer(id: 'ZZZZZZZZZZZZZZZZ', key: 'k', name: 'Lab Linux', os: 'linux', host: '10.0.0.7', port: 47100, lastSeen: DateTime(2030)),
      DiscoveredPeer(id: 'K7M2P9XQ4TAB8HDE', key: 'k', name: 'Office PC', os: 'windows', host: '10.0.0.8', port: 47100, lastSeen: DateTime(2030)),
    ];

    test('empty query lists everything once', () {
      final items = paletteItems(query: '', entries: entries, peers: peers);
      expect(items.map((i) => i.title), ['Office PC', 'Kitchen', 'Lab Linux']);
    });

    test('filters by name, alias, tag and ID', () {
      expect(paletteItems(query: 'kitch', entries: entries, peers: peers).map((i) => i.title), ['Kitchen']);
      expect(paletteItems(query: 'finance', entries: entries, peers: peers).map((i) => i.title), ['Office PC']);
      expect(paletteItems(query: 'lab', entries: entries, peers: peers).map((i) => i.title), ['Lab Linux']);
    });

    test('a pasted target becomes a direct "Connect to" entry first', () {
      final items = paletteItems(query: '203.0.113.5', entries: entries, peers: peers);
      expect(items.first.title, 'Connect to 203.0.113.5');
      expect(items.first.target.addresses.single.hostPort, '203.0.113.5:47100');
    });
  });

  group('small helpers', () {
    test('architecture parsing', () {
      expect(parseArch('3.13.5 (stable) on "macos_x64"'), 'x64');
      expect(parseArch('3.13.5 (stable) on "macos_arm64"'), 'arm64');
      expect(parseArch('3.13.5 (stable) on "windows_ia32"'), 'x86');
      expect(parseArch('3.13.5 (stable) on "android_arm"'), 'arm');
      expect(parseArch('weird'), 'x64');
    });

    test('formatters', () {
      expect(formatDuration(const Duration(seconds: 75)), '01:15');
      expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
      expect(formatLastSeen(null), 'never');
      final now = DateTime(2030, 1, 1, 12);
      expect(formatLastSeen(now.subtract(const Duration(seconds: 5)), now: now), 'just now');
      expect(formatLastSeen(now.subtract(const Duration(minutes: 7)), now: now), '7 min ago');
      expect(formatLastSeen(now.subtract(const Duration(hours: 3)), now: now), '3 h ago');
      expect(formatLastSeen(now.subtract(const Duration(days: 2)), now: now), '2 d ago');
      expect(formatBitrate(2500000), '2.5 Mbps');
      expect(formatBitrate(640000), '640 kbps');
      expect(osLabel('macos'), 'macOS');
      expect(osIcon('android'), Icons.phone_android_rounded);
    });
  });
}
