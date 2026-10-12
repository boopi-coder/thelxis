import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/core/address_book.dart';
import 'package:thelxis/core/log.dart';
import 'package:thelxis/core/system_info.dart';
import 'package:thelxis/net/discovery.dart';
import 'package:thelxis/net/peer_identity.dart';
import 'package:thelxis/platform/host_platform.dart';
import 'package:thelxis/protocol/control_messages.dart';
import 'package:thelxis/session/session_history.dart';
import 'package:thelxis/session/session_manager.dart';
import 'package:thelxis/ui/home/controlled_banner.dart';
import 'package:thelxis/ui/theme.dart';

import 'support/fakes.dart';
import 'support/host_rig.dart';

/// The host side of PROTOCOL.md 6.2 `input_state`: the person at this device
/// sees why the viewer's input has no effect and can reopen the settings pane.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Logger.sink = (_, _) {};

  late HostRig rig;
  late SessionManager manager;

  Future<void> connect(WidgetTester tester) async {
    await tester.runAsync(() async {
      rig = HostRig();
      await rig.setUp(inputCheckInterval: const Duration(milliseconds: 20));
      rig.platform.inputControlStatus = PermissionStatus.denied;
      final prefs = await SharedPreferences.getInstance();
      manager = SessionManager(
        settings: rig.settings,
        identity: rig.hostId,
        systemInfo: SystemInfo.fallback(),
        trusted: rig.trusted,
        addressBook: AddressBook(prefs),
        credentials: rig.creds,
        connectivity: FakeConnectivity(),
        platform: rig.platform,
        lan: LanDiscovery(
          identity: rig.hostId,
          localInfo: () => const LocalPeerInfo(name: 'x', os: 'linux', app: '0'),
          signalingPort: () => 0,
        ),
        history: SessionHistory(rig.settings),
        badge: FakeBadge(),
      );
      manager.trackHostSession(rig.session);
      rig.open();
      rig.session.debugReceiveControl(await rig.passwordAuth(rig.creds.oneTimePassword));
      await untilTrue(() => rig.session.inputIssue == InputIssue.permission);
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SessionManager>.value(value: manager),
          Provider<HostPlatform>.value(value: rig.platform),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const Scaffold(body: ControlledBanner()),
        ),
      ),
    );
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await rig.tearDown();
      manager.dispose();
    });
  }

  testWidgets('macOS: a missing grant is explained, with a button back to the settings pane', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await connect(tester);
    expect(find.byKey(const ValueKey('banner-input-issue')), findsOneWidget);
    expect(find.textContaining('"Accessibility" permission'), findsOneWidget);
    expect(find.textContaining('turn it off and on again'), findsOneWidget,
        reason: 'a stale grant after an update looks switched on');

    final before = rig.platform.permissionRequests.length;
    await tester.tap(find.text('Open settings'));
    await tester.pump();
    expect(rig.platform.permissionRequests, hasLength(before + 1));
    expect(rig.platform.permissionRequests.last, HostPermission.inputControl);
    debugDefaultTargetPlatformOverride = null;
    await finish(tester);
  });

  testWidgets('Android names the accessibility service; the row goes away once it is on', (tester) async {
    await connect(tester);
    expect(find.textContaining('turn on the Thelxis service'), findsOneWidget);
    await tester.runAsync(() async {
      rig.platform.inputControlStatus = PermissionStatus.granted;
      await untilTrue(() => rig.session.inputIssue == null);
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('banner-input-issue')), findsNothing);
    expect(find.textContaining('Controlled by'), findsOneWidget);
    await finish(tester);
  });
}
