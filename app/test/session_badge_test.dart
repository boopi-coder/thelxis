import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/core/address_book.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/log.dart';
import 'package:thelxis/core/settings.dart';
import 'package:thelxis/core/system_info.dart';
import 'package:thelxis/core/trusted_devices.dart';
import 'package:thelxis/net/discovery.dart';
import 'package:thelxis/net/peer_identity.dart';
import 'package:thelxis/protocol/models.dart';
import 'package:thelxis/session/host_credentials.dart';
import 'package:thelxis/session/host_session.dart';
import 'package:thelxis/session/prompts.dart';
import 'package:thelxis/session/session_base.dart';
import 'package:thelxis/session/session_history.dart';
import 'package:thelxis/session/session_manager.dart';

import 'support/fakes.dart';
import 'support/host_rig.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Logger.sink = (_, _) {};

  late FakeBadge badge;
  late SessionManager manager;
  late AppSettings settings;
  late Identity hostId;
  late FakeHostPlatform platform;
  final rigs = <HostRig>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    badge = FakeBadge();
    hostId = await Identity.fromSeed(List<int>.filled(32, 31));
    settings = AppSettings(prefs, defaultDeviceName: 'Host');
    platform = FakeHostPlatform();
    manager = SessionManager(
      settings: settings,
      identity: hostId,
      systemInfo: SystemInfo.fallback(),
      trusted: TrustedDevices(prefs),
      addressBook: AddressBook(prefs),
      credentials: HostCredentials(identity: hostId, settings: settings),
      connectivity: FakeConnectivity(),
      platform: platform,
      lan: LanDiscovery(
        identity: hostId,
        localInfo: () => const LocalPeerInfo(name: 'x', os: 'linux', app: '0'),
        signalingPort: () => 0,
      ),
      history: SessionHistory(settings),
      badge: badge,
    );
    // Subscribes to the badge's Stop button; the listener stays off.
    await manager.start();
  });

  tearDown(() async {
    for (final r in rigs) {
      await r.tearDown();
    }
    rigs.clear();
    manager.dispose();
  });

  /// A host session tracked by [manager], authorized through the real flow.
  Future<HostRig> connectViewer(String name, {int seed = 40, Completer<void>? holdCapture}) async {
    final rig = HostRig();
    await rig.setUp();
    rigs.add(rig);
    final session = HostSession(
      env: HostEnv(
        settings: settings,
        identity: hostId,
        trusted: rig.trusted,
        credentials: rig.creds,
        platform: platform,
        captures: manager.captures,
        requestApproval: (p) async => const ApprovalResult(accepted: true, permissions: Permissions()),
        onNotice: (t, m) {},
        startCapture: (d, all, {int fps = 30}) async {
          await holdCapture?.future;
          return rig.streamFor(d);
        },
      ),
      peer: PeerIdentity(key: 'key-$name', id: 'ID$seed', name: name, os: 'macos'),
      channel: rig.pair.channel,
      sid: 'sid-$name',
    )
      ..debugControlTap = rig.sent.add
      ..debugFingerprints = () async => (local: kFpLocal, remote: kFpRemote);
    manager.trackHostSession(session);
    rig.session = session;
    return rig;
  }

  Future<void> authorize(HostRig rig) async {
    rig.session.debugControlOpened();
    rig.session.debugReceiveControl({'t': 'auth', 'method': 'request', 'user': 'x'});
  }

  test('nothing is shown until someone is connected', () {
    expect(badge.shown, isEmpty);
    expect(badge.dismissCalls, 0);
  });

  test('the badge appears when a viewer gets the screen and names who it is', () async {
    final rig = await connectViewer('Alice');
    await authorize(rig);
    await untilTrue(() => badge.shown.isNotEmpty);
    final s = badge.shown.last;
    expect(s.peers, ['Alice']);
    expect(s.label, 'Connected: Alice');
    expect(s.stopLabel, 'Disconnect');
    expect(s.controlActive, isTrue);
    expect(s.since.isAfter(DateTime.now().subtract(const Duration(minutes: 1))), isTrue);
    expect(badge.current, isNotNull);
  });

  test('the badge is up as soon as capture starts, before the session is "active"', () async {
    final hold = Completer<void>();
    final rig = await connectViewer('Alice', holdCapture: hold);
    await authorize(rig);
    // Capture has begun but the screen frame is not even created yet.
    await untilTrue(() => rig.session.sharing);
    expect(rig.session.phase, isNot(SessionPhase.active));
    expect(badge.current, isNotNull, reason: 'capture running means the badge must be visible');
    hold.complete();
    await untilTrue(() => rig.session.phase == SessionPhase.active);
    expect(badge.current, isNotNull);
  });

  test('several viewers: Russian plural label, and the earliest start is used', () async {
    await settings.setLanguage('ru');
    final a = await connectViewer('Alice');
    await authorize(a);
    await untilTrue(() => badge.shown.isNotEmpty);
    expect(badge.shown.last.label, 'Подключён: Alice');
    expect(badge.shown.last.stopLabel, 'Отключить');
    final firstSince = badge.shown.last.since;

    await Future<void>.delayed(const Duration(milliseconds: 20));
    final b = await connectViewer('Bob', seed: 41);
    await authorize(b);
    await untilTrue(() => badge.shown.last.peers.length == 2);
    expect(badge.shown.last.label, 'Подключено: 2');
    expect(badge.shown.last.since, firstSince);
    await settings.setLanguage('en');
    await untilTrue(() => badge.shown.last.label == 'Connected: 2');
  });

  test('dismiss happens exactly once, only after the last viewer is gone', () async {
    final a = await connectViewer('Alice');
    final b = await connectViewer('Bob', seed: 41);
    await authorize(a);
    await authorize(b);
    await untilTrue(() => badge.shown.isNotEmpty && badge.shown.last.peers.length == 2);

    await a.session.end('user');
    await untilTrue(() => badge.shown.last.peers.length == 1);
    expect(badge.dismissCalls, 0, reason: 'one viewer is still connected');
    expect(badge.current, isNotNull);

    await b.session.end('user');
    await untilTrue(() => badge.dismissCalls == 1);
    expect(badge.current, isNull);
    expect(manager.liveHostSessions, isEmpty);
  });

  test('pressing Stop on the badge ends every incoming session', () async {
    final a = await connectViewer('Alice');
    final b = await connectViewer('Bob', seed: 41);
    await authorize(a);
    await authorize(b);
    await untilTrue(() => badge.shown.isNotEmpty && badge.shown.last.peers.length == 2);
    badge.pressStop();
    await untilTrue(() => a.session.isEnded && b.session.isEnded);
    await untilTrue(() => badge.dismissCalls == 1);
    expect(badge.current, isNull);
  });

  test('a session that is only being authorized does not show the badge', () async {
    final rig = await connectViewer('Alice');
    rig.session.debugControlOpened();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(badge.shown, isEmpty);
  });

  test('view-only viewers show the badge without the control accent', () async {
    final rig = await connectViewer('Alice');
    rig.session.debugControlOpened();
    rig.session.debugReceiveControl({'t': 'auth', 'method': 'request', 'user': 'x'});
    await untilTrue(() => badge.shown.isNotEmpty);
    rig.session.setControlAllowed(false);
    await untilTrue(() => badge.shown.last.controlActive == false);
    expect(badge.shown.last.peers, ['Alice']);
  });
}
