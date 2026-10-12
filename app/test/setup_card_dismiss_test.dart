import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/app.dart';
import 'package:thelxis/app_services.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/system_info.dart';
import 'package:thelxis/platform/host_platform.dart';

import 'support/fakes.dart';

/// Desktop host whose screen-capture and input statuses tests can flip.
class _Perms extends FakeHostPlatform {
  PermissionStatus screen = PermissionStatus.granted;
  PermissionStatus inputStatus = PermissionStatus.denied;

  @override
  Future<PermissionStatus> permissionStatus(HostPermission permission) async =>
      permission == HostPermission.screenCapture ? screen : inputStatus;
}

/// [stored] seeds SharedPreferences as a previous run would have left them.
Future<AppServices> _services(_Perms platform, {Map<String, Object> stored = const {}}) async {
  SharedPreferences.setMockInitialValues(stored);
  final prefs = await SharedPreferences.getInstance();
  return AppServices.create(
    prefs: prefs,
    identity: await Identity.fromSeed(List<int>.generate(32, (i) => i + 3)),
    systemInfo: const SystemInfo(
      os: 'macos',
      osVersion: 'test',
      arch: 'x64',
      hostname: 'h',
      appVersion: '0.3.2',
      defaultDeviceName: 'Test Machine',
    ),
    connectivity: FakeConnectivity(addresses: ['192.168.1.5:47100']),
    platform: platform,
    badge: FakeBadge(),
  );
}

Future<AppServices> _pump(WidgetTester tester, _Perms platform, {Map<String, Object> stored = const {}}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final services = await _services(platform, stored: stored);
  await tester.pumpWidget(ThelxisApp(services: services));
  await tester.pump(const Duration(milliseconds: 300));
  return services;
}

final _card = find.byKey(const ValueKey('setup-card'));
final _close = find.byKey(const ValueKey('setup-dismiss'));

void main() {
  testWidgets('the close button hides the card, persists the missing set and points to Settings', (tester) async {
    final services = await _pump(tester, _Perms());
    expect(_card, findsOneWidget);
    expect(find.byTooltip('Hide'), findsOneWidget);
    final semantics = tester.ensureSemantics();
    expect(
      tester.getSemantics(_close),
      matchesSemantics(
        label: 'Hide the setup hint',
        tooltip: 'Hide',
        isButton: true,
        hasTapAction: true,
        isEnabled: true,
        hasEnabledState: true,
        isFocusable: true,
        hasFocusAction: true,
      ),
    );
    semantics.dispose();

    await tester.tap(_close);
    await tester.pump();
    expect(_card, findsNothing);
    expect(find.text('You can reopen this in Settings'), findsOneWidget);
    expect(services.settings.dismissedSetupPermissions, {'inputControl'});
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('setup_dismissed_perms'), 'inputControl');

    // A resume re-reads the same set: still hidden.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_card, findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('after a restart the same missing set stays hidden', (tester) async {
    await _pump(tester, _Perms(), stored: {'setup_dismissed_perms': 'inputControl'});
    expect(_card, findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a permission that goes missing later brings the card back', (tester) async {
    final platform = _Perms()..screen = PermissionStatus.denied;
    final services = await _pump(tester, platform, stored: {'setup_dismissed_perms': 'inputControl'});
    expect(_card, findsOneWidget);
    expect(find.text('Grant'), findsNWidgets(2), reason: 'all missing permissions are listed again');

    await tester.tap(_close);
    await tester.pump();
    expect(_card, findsNothing);
    expect(services.settings.dismissedSetupPermissions, {'inputControl', 'screenCapture'});

    // Only one of the closed ones missing now: no reason to nag.
    platform.screen = PermissionStatus.granted;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_card, findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Settings row shows the statuses and opens the guide with a working Grant', (tester) async {
    final platform = _Perms();
    await _pump(tester, platform, stored: {'setup_dismissed_perms': 'inputControl'});
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey('host-perms-row'));
    expect(row, findsOneWidget);
    expect(find.text('Permissions for controlling this device'), findsOneWidget);
    expect(find.text('Screen capture: Allowed · Input control: Not allowed'), findsOneWidget);

    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('host-perms-dialog')), findsOneWidget);
    expect(find.text('Not allowed'), findsOneWidget);
    expect(find.byKey(const ValueKey('host-perms-grant-screenCapture')), findsNothing);

    platform.inputStatus = PermissionStatus.granted;
    await tester.tap(find.byKey(const ValueKey('host-perms-grant-inputControl')));
    await tester.pumpAndSettle();
    expect(platform.permissionRequests, [HostPermission.inputControl]);
    expect(find.text('Not allowed'), findsNothing, reason: 'the dialog re-reads the status');

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Screen capture: Allowed · Input control: Allowed'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
