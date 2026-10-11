import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/app.dart';
import 'package:thelxis/app_services.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/system_info.dart';
import 'package:thelxis/net/peer_identity.dart';
import 'package:thelxis/platform/host_platform.dart';
import 'package:thelxis/ui/theme.dart';
import 'package:thelxis/ui/widgets/common.dart';
import 'package:thelxis/ui/widgets/hover_tint.dart';

import 'support/fakes.dart';

class _Denied extends FakeHostPlatform {
  @override
  Future<PermissionStatus> permissionStatus(HostPermission permission) async => PermissionStatus.denied;
}

class _CountingChild extends StatelessWidget {
  const _CountingChild(this.onBuild);
  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return const SizedBox(width: 120, height: 40, child: Text('row'));
  }
}

Future<AppServices> _services({HostPlatform? platform, bool withDevice = false}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final services = AppServices.create(
    prefs: prefs,
    identity: await Identity.fromSeed(List<int>.generate(32, (i) => i + 3)),
    systemInfo: const SystemInfo(
      os: 'linux',
      osVersion: 'test',
      arch: 'x64',
      hostname: 'h',
      appVersion: '0.2.0',
      defaultDeviceName: 'Test Machine',
    ),
    connectivity: FakeConnectivity(addresses: ['192.168.1.5:47100']),
    platform: platform ?? FakeHostPlatform(),
    badge: FakeBadge(),
  );
  if (withDevice) {
    final peer = await Identity.fromSeed(List<int>.filled(32, 77));
    await services.addressBook.upsertPeer(
      PeerIdentity(key: peer.publicKeyB64, id: peer.id, name: 'Office PC', os: 'windows', addresses: ['203.0.113.7:47100']),
      connected: true,
    );
  }
  return services;
}

void main() {
  testWidgets('hovering a row repaints its wash only: the content is not rebuilt', (tester) async {
    var builds = 0;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: Center(
          child: HoverTint(onTap: () {}, child: _CountingChild(() => builds++)),
        ),
      ),
    ));
    expect(builds, 1);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('row')));
    await tester.pump();
    await mouse.moveTo(const Offset(2, 2));
    await tester.pump();
    await mouse.moveTo(tester.getCenter(find.text('row')));
    await tester.pump();
    expect(builds, 1, reason: 'hover must not rebuild the child subtree');
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('the app has no blur layers or gradients ($brightness)', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final services = await _services(withDevice: true);
      await services.settings.setThemeMode(brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light);
      await tester.pumpWidget(ThelxisApp(services: services));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(BackdropFilter), findsNothing);
      final gradient = find.byWidgetPredicate(
        (w) => w is DecoratedBox && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).gradient != null,
      );
      expect(gradient, findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('every toast can be closed, also one that carries an action', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Column(children: [
            TextButton(onPressed: () => showMessage(context, 'plain toast'), child: const Text('plain')),
            TextButton(
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: const Text('with action'), action: SnackBarAction(label: 'Do', onPressed: () {})),
              ),
              child: const Text('action'),
            ),
          ]),
        ),
      ),
    ));
    for (final (button, text) in [('plain', 'plain toast'), ('action', 'with action')]) {
      await tester.tap(find.text(button));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(text), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget, reason: '$text has a close button');
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text(text), findsNothing);
    }
  });

  testWidgets('Home: missing OS permissions appear in one compact "Setup needed" card', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = await _services(platform: _Denied());
    await tester.pumpWidget(ThelxisApp(services: services));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('setup-card')), findsOneWidget);
    expect(find.text('Setup needed'), findsOneWidget);
    expect(find.text('Grant'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Home: no setup card when nothing is missing; devices grid and empty state', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var services = await _services();
    await tester.pumpWidget(ThelxisApp(services: services));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('setup-card')), findsNothing);
    expect(find.text('No devices yet'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    services = await _services(withDevice: true);
    await tester.pumpWidget(ThelxisApp(services: services));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('No devices yet'), findsNothing);
    expect(find.text('Office PC'), findsWidgets);
    expect(find.byType(GridView), findsNothing, reason: 'a sliver grid, not a nested scroll view');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Home: the device tile shows Connect only while hovered', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = await _services(withDevice: true);
    await tester.pumpWidget(ThelxisApp(services: services));
    await tester.pump(const Duration(milliseconds: 300));
    // "Connect" labels: the primary button of the Connect card only.
    final before = find.text('Connect').evaluate().length;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    final tile = find.text('Office PC').last;
    await mouse.moveTo(tester.getCenter(tile));
    await tester.pump();
    expect(find.text('Connect').evaluate().length, before + 1);
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(find.text('Connect').evaluate().length, before);
    await tester.pumpWidget(const SizedBox());
  });
}
