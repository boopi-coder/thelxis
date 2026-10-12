import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/app.dart';
import 'package:thelxis/app_services.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/system_info.dart';
import 'package:thelxis/platform/impl/android_host.dart';

import 'support/fakes.dart';

const _channel = MethodChannel('io.thelxis/host');

/// Stands in for HostChannel.kt and records what Dart asked for.
class _FakeAndroid {
  bool accessibilityOn = false;
  bool restrictedLikely = true;
  bool failEverything = false;
  final List<String> calls = [];

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      if (failEverything) throw PlatformException(code: 'native_error');
      switch (call.method) {
        case 'isAccessibilityEnabled':
          return accessibilityOn;
        case 'isRestrictedSettingsLikely':
          return restrictedLikely && !accessibilityOn;
      }
      return null;
    });
  }

  void remove() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
  }
}

Future<AppServices> _services(AndroidHostPlatform platform) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return AppServices.create(
    prefs: prefs,
    identity: await Identity.fromSeed(List<int>.generate(32, (i) => i + 3)),
    systemInfo: const SystemInfo(
      os: 'android',
      osVersion: '14',
      arch: 'arm64',
      hostname: 'h',
      appVersion: '0.3.1',
      defaultDeviceName: 'Phone',
    ),
    connectivity: FakeConnectivity(addresses: ['192.168.1.5:47100']),
    platform: platform,
    badge: FakeBadge(),
  );
}

Future<void> _pumpHome(WidgetTester tester, _FakeAndroid native) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  native.install();
  addTearDown(native.remove);
  final services = await _services(AndroidHostPlatform());
  await tester.pumpWidget(ThelxisApp(services: services));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('restricted sideload: the card shows the three-step guide and each button opens its screen', (tester) async {
    final native = _FakeAndroid();
    await _pumpHome(tester, native);

    expect(find.byKey(const ValueKey('setup-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('accessibility-guide')), findsOneWidget);
    expect(find.textContaining('Allow restricted settings'), findsWidgets);
    expect(find.text('Grant'), findsNothing, reason: 'the steps replace the single Grant button');

    native.calls.clear();
    await tester.ensureVisible(find.byKey(const ValueKey('guide-step1')));
    await tester.tap(find.byKey(const ValueKey('guide-step1')));
    await tester.pump();
    expect(native.calls, contains('openAccessibilitySettings'));

    native.calls.clear();
    await tester.ensureVisible(find.byKey(const ValueKey('guide-step2')));
    await tester.tap(find.byKey(const ValueKey('guide-step2')));
    await tester.pump();
    expect(native.calls, contains('openAppDetails'));
    expect(native.calls, isNot(contains('openAccessibilitySettings')));

    native.calls.clear();
    await tester.ensureVisible(find.byKey(const ValueKey('guide-step3')));
    await tester.tap(find.byKey(const ValueKey('guide-step3')));
    await tester.pump();
    expect(native.calls, contains('openAccessibilitySettings'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('not restricted: plain row with the Grant button and the one-line hint', (tester) async {
    final native = _FakeAndroid()..restrictedLikely = false;
    await _pumpHome(tester, native);

    expect(find.byKey(const ValueKey('setup-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('accessibility-guide')), findsNothing);
    expect(find.text('Grant'), findsOneWidget);
    expect(find.textContaining('If the switch is greyed out'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the card goes away when the app resumes with the service enabled', (tester) async {
    final native = _FakeAndroid();
    await _pumpHome(tester, native);
    expect(find.byKey(const ValueKey('accessibility-guide')), findsOneWidget);

    // The user enabled the service in system settings and comes back.
    native.accessibilityOn = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('accessibility-guide')), findsNothing);
    expect(find.byKey(const ValueKey('setup-card')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('"Check again" re-reads the service state without leaving the app', (tester) async {
    final native = _FakeAndroid();
    await _pumpHome(tester, native);
    expect(find.byKey(const ValueKey('accessibility-guide')), findsOneWidget);

    native.accessibilityOn = true;
    // Centred, not just on screen: at the bottom edge the phone navigation
    // bar would take the tap.
    final recheck = find.byKey(const ValueKey('guide-recheck'));
    await Scrollable.ensureVisible(tester.element(recheck), alignment: 0.5);
    await tester.pump();
    // A missed tap must fail the test, not land elsewhere and pass by accident.
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);
    await tester.tap(recheck);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('setup-card')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('closed card: Settings still opens the restricted-settings guide', (tester) async {
    final native = _FakeAndroid()..restrictedLikely = false;
    await _pumpHome(tester, native);
    await tester.tap(find.byKey(const ValueKey('setup-dismiss')));
    await tester.pump();
    expect(find.byKey(const ValueKey('setup-card')), findsNothing);

    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('host-perms-row'));
    expect(find.text('Screen capture: Asked at each connection · Input control: Not allowed'), findsOneWidget);
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    // The user came on purpose: the walk-through shows even when the block
    // is not detected.
    expect(find.byKey(const ValueKey('accessibility-guide')), findsOneWidget);

    native.calls.clear();
    await tester.ensureVisible(find.byKey(const ValueKey('guide-step2')));
    await tester.tap(find.byKey(const ValueKey('guide-step2')));
    await tester.pump();
    expect(native.calls, contains('openAppDetails'));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  group('AndroidHostPlatform helpers', () {
    final native = _FakeAndroid();
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      native.calls.clear();
      native
        ..accessibilityOn = false
        ..failEverything = false
        ..install();
    });
    tearDown(native.remove);

    test('isRestrictedSettingsLikely mirrors the native answer', () async {
      final p = AndroidHostPlatform();
      native.restrictedLikely = true;
      expect(await p.isRestrictedSettingsLikely(), isTrue);
      native.restrictedLikely = false;
      expect(await p.isRestrictedSettingsLikely(), isFalse);
      native.accessibilityOn = true;
      native.restrictedLikely = true;
      expect(await p.isRestrictedSettingsLikely(), isFalse, reason: 'enabled means nothing to unlock');
    });

    test('native failures never throw: not restricted, openAppDetails is a no-op', () async {
      native.failEverything = true;
      final p = AndroidHostPlatform();
      expect(await p.isRestrictedSettingsLikely(), isFalse);
      await p.openAppDetails();
      expect(native.calls, ['isRestrictedSettingsLikely', 'openAppDetails']);
    });

    test('openAppDetails calls the native method', () async {
      await AndroidHostPlatform().openAppDetails();
      expect(native.calls, ['openAppDetails']);
    });
  });
}
