import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/app.dart';
import 'package:thelxis/app_services.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/links.dart';
import 'package:thelxis/core/system_info.dart';
import 'package:thelxis/l10n/strings.dart';

import 'support/fakes.dart';

Future<AppServices> _services(String language) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final identity = await Identity.fromSeed(
    List<int>.generate(32, (i) => i + 50),
  );
  final services = AppServices.create(
    prefs: prefs,
    identity: identity,
    systemInfo: const SystemInfo(
      os: 'linux',
      osVersion: 'test',
      arch: 'x64',
      hostname: 'test-host',
      appVersion: '0.1.0',
      defaultDeviceName: 'Test PC',
    ),
    connectivity: FakeConnectivity(addresses: ['192.168.1.5:47100']),
    platform: FakeHostPlatform(),
    badge: FakeBadge(),
  );
  await services.settings.setLanguage(language);
  return services;
}

void main() {
  late List<Uri> launched;

  setUp(() {
    launched = [];
    externalLauncher = (uri) async {
      launched.add(uri);
      return true;
    };
  });
  tearDown(() {
    externalLauncher = null;
    S.current = S.forLanguage(AppLanguage.english);
  });

  test('the Boosty URL constant', () {
    expect(kBoostyUrl, 'https://boosty.to/boopi_coder');
  });

  for (final lang in ['en', 'ru']) {
    final s = S.forLanguage(AppLanguage.fromCode(lang));

    Future<void> pump(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ThelxisApp(services: await _services(lang)));
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('$lang: Settings → About card opens Boosty', (tester) async {
      await pump(tester, const Size(420, 900));
      await tester.tap(find.text(s.t('nav.settings')).last);
      await tester.pump(const Duration(milliseconds: 450));
      final button = find.text(s.t('support.button'));
      // Settings is a long lazy list: scroll to the end, where About lives.
      await tester.drag(find.byType(ListView).first, const Offset(0, -20000));
      await tester.pump();
      await tester.ensureVisible(button);
      await tester.pump();
      expect(find.text(s.t('support.title')), findsOneWidget);
      expect(find.text(s.t('support.body')), findsOneWidget);
      await tester.tap(button);
      expect(launched, [Uri.parse(kBoostyUrl)]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('$lang: wide sidebar shows a labelled link', (tester) async {
      await pump(tester, const Size(1400, 900));
      expect(find.text(s.t('support.link')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('support-link')));
      expect(launched, [Uri.parse(kBoostyUrl)]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('$lang: icon rail shows only a heart with a tooltip', (
      tester,
    ) async {
      await pump(tester, const Size(800, 600));
      expect(find.text(s.t('support.link')), findsNothing);
      expect(find.byTooltip(s.t('support.title')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('support-link')));
      expect(launched, [Uri.parse(kBoostyUrl)]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('$lang: phone has no link outside Settings', (tester) async {
      await pump(tester, const Size(360, 640));
      expect(find.byKey(const ValueKey('support-link')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
