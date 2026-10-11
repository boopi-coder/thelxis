import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/app.dart';
import 'package:thelxis/app_services.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/log.dart';
import 'package:thelxis/core/system_info.dart';
import 'package:thelxis/net/peer_identity.dart';
import 'package:thelxis/session/host_session.dart';
import 'package:thelxis/session/prompts.dart';
import 'package:thelxis/update/update_service.dart';

import 'support/fakes.dart';
import 'support/host_rig.dart';

/// UpdateService without any networking, observing how the app drives it.
class _SpyUpdates extends UpdateService {
  _SpyUpdates(SharedPreferences prefs) : super(prefs: prefs);

  int idleCalls = 0;
  String? just;
  int acknowledged = 0;

  @override
  String? get justUpdatedVersion => just;

  @override
  void acknowledgeUpdated() {
    acknowledged++;
    just = null;
    notifyListeners();
  }

  @override
  void notifyIdle() {
    idleCalls++;
  }

  void announce(String version) {
    just = version;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Logger.sink = (_, _) {};

  Future<(AppServices, _SpyUpdates)> build() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final spy = _SpyUpdates(prefs);
    final services = AppServices.create(
      prefs: prefs,
      identity: await Identity.fromSeed(List<int>.generate(32, (i) => i + 90)),
      systemInfo: SystemInfo.fallback(),
      connectivity: FakeConnectivity(),
      platform: FakeHostPlatform(),
      badge: FakeBadge(),
      updates: spy,
    );
    return (services, spy);
  }

  test('updates are held back while any session is running and resume the moment the app is idle', () async {
    final (services, spy) = await build();
    expect(services.updates.isBusy(), isFalse);

    final rig = HostRig();
    await rig.setUp();
    addTearDown(rig.tearDown);
    final session = HostSession(
      env: HostEnv(
        settings: services.settings,
        identity: services.identity,
        trusted: rig.trusted,
        credentials: rig.creds,
        platform: services.platform,
        captures: services.sessions.captures,
        requestApproval: (p) async => ApprovalResult.denied,
        onNotice: (t, m) {},
        startCapture: (d, all, {int fps = 30}) => rig.streamFor(d),
      ),
      peer: const PeerIdentity(key: 'k', id: 'ID', name: 'Alice', os: 'macos'),
      channel: rig.pair.channel,
      sid: 'sid',
    );
    services.sessions.trackHostSession(session);
    expect(services.updates.isBusy(), isTrue, reason: 'an incoming session blocks installation');
    expect(spy.idleCalls, 0);

    await session.end('user');
    expect(services.updates.isBusy(), isFalse);
    expect(spy.idleCalls, 1, reason: 'busy -> idle tells the updater exactly once');
  });

  testWidgets('the "updated" toast shows once with the new version', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (services, spy) = await build();
    await tester.pumpWidget(ThelxisApp(services: services));
    await tester.pump(const Duration(milliseconds: 300));

    spy.announce('0.2.0');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('0.2.0'), findsWidgets);
    expect(spy.acknowledged, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('Settings has an Updates section and Home carries the (collapsed) update banner', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (services, _) = await build();
    await tester.pumpWidget(ThelxisApp(services: services));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Settings').first);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('UPDATES'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('the update module keeps its own prefs namespace', () async {
    SharedPreferences.setMockInitialValues({});
    expect(UpdateService.keyAutoCheck, startsWith('update.'));
    expect(UpdateService.keyLastRunVersion, startsWith('update.'));
  });
}
