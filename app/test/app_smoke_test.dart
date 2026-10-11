import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/app.dart';
import 'package:thelxis/app_services.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/system_info.dart';

import 'support/fakes.dart';

Future<AppServices> _services() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final identity = await Identity.fromSeed(List<int>.generate(32, (i) => i + 9));
  return AppServices.create(
    prefs: prefs,
    identity: identity,
    systemInfo: const SystemInfo(
      os: 'linux',
      osVersion: 'test',
      arch: 'x64',
      hostname: 'test-host',
      appVersion: '0.1.0',
      defaultDeviceName: 'Test Machine',
    ),
    connectivity: FakeConnectivity(addresses: ['192.168.1.5:47100']),
    platform: FakeHostPlatform(),
    badge: FakeBadge(),
  );
}

void main() {
  testWidgets('the app shell shows Home with the ID card, password and connect field', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = await _services();

    await tester.pumpWidget(ThelxisApp(services: services));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('YOUR THELXIS ID'), findsOneWidget);
    expect(find.text(services.identity.formattedId), findsWidgets);
    expect(find.text('One-time password'), findsOneWidget);
    expect(find.text('••••••••'), findsOneWidget);
    expect(find.text('Allow incoming connections'), findsOneWidget);
    expect(find.text('Share access'), findsOneWidget);
    expect(find.text('Connect to a device'), findsOneWidget);
    expect(find.byType(NavigationRail), findsOneWidget, reason: 'wide layout uses a rail');
    expect(find.byType(NavigationBar), findsNothing);
    // The unstarted listener is reported honestly.
    expect(find.textContaining('Listener unavailable'), findsOneWidget);

    await tester.tap(find.byTooltip('Show'));
    await tester.pump();
    expect(find.text(services.credentials.oneTimePassword), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('narrow screens use the bottom navigation and every page opens', (tester) async {
    // Tall enough that the lazily built settings list shows every section.
    tester.view.physicalSize = const Size(400, 4200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = await _services();

    await tester.pumpWidget(ThelxisApp(services: services));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);

    await tester.tap(find.text('Devices'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('ADDRESS BOOK'), findsOneWidget);
    expect(find.text('ON THIS NETWORK'), findsOneWidget);

    await tester.tap(find.text('Sessions'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('YOUR CONNECTIONS'), findsOneWidget);

    await tester.tap(find.text('Settings'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('SECURITY'), findsOneWidget);
    expect(find.text('TRUSTED DEVICES'), findsOneWidget);
    expect(find.text('No trusted devices'), findsOneWidget);
    expect(find.text('CONNECTIVITY'), findsOneWidget);
    expect(find.text('Use public STUN servers'), findsOneWidget);

    await tester.tap(find.text('Home'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('YOUR THELXIS ID'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('typing an invalid target shows an inline error and does not connect', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = await _services();

    await tester.pumpWidget(ThelxisApp(services: services));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).first, 'definitely not valid!');
    await tester.tap(find.text('Connect'));
    await tester.pump();
    expect(find.textContaining('invite link'), findsWidgets);
    expect(services.sessions.viewerSessions, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('light theme builds', (tester) async {
    final services = await _services();
    await services.settings.setThemeMode(ThemeMode.light);
    await tester.pumpWidget(ThelxisApp(services: services));
    await tester.pump(const Duration(milliseconds: 300));
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.light);
    await tester.pumpWidget(const SizedBox());
  });
}
