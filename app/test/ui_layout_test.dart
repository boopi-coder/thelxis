import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/app.dart';
import 'package:thelxis/app_services.dart';
import 'package:thelxis/core/address_book.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/system_info.dart';
import 'package:thelxis/core/trusted_devices.dart';
import 'package:thelxis/net/peer_identity.dart';
import 'package:thelxis/protocol/models.dart';
import 'package:thelxis/l10n/strings.dart';

import 'support/fakes.dart';

Future<AppServices> _services({String language = 'en', ThemeMode theme = ThemeMode.dark}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final identity = await Identity.fromSeed(List<int>.generate(32, (i) => i + 50));
  final services = AppServices.create(
    prefs: prefs,
    identity: identity,
    systemInfo: const SystemInfo(
      os: 'linux',
      osVersion: 'test',
      arch: 'x64',
      hostname: 'test-host',
      appVersion: '0.1.0',
      defaultDeviceName: 'A rather long device name that must not overflow its card',
    ),
    connectivity: FakeConnectivity(addresses: ['192.168.1.5:47100', '[2001:db8::1]:47100']),
    platform: FakeHostPlatform(),
    badge: FakeBadge(),
  );
  await services.settings.setLanguage(language);
  await services.settings.setThemeMode(theme);
  // Populate lists so rows, chips and tags are laid out too.
  await services.addressBook.upsertPeer(
    PeerIdentity(
      key: 'k1',
      id: 'K7M2P9XQ4TAB8HDE',
      name: 'Очень длинное имя компьютера бухгалтерии',
      os: 'windows',
      addresses: ['203.0.113.5:47100'],
    ),
    connected: true,
  );
  await services.addressBook.update('K7M2P9XQ4TAB8HDE', tags: ['finance', 'reception', 'floor-2'], favorite: true);
  await services.trusted.add(
    key: 'k1',
    id: 'K7M2P9XQ4TAB8HDE',
    name: 'Alice with a very long display name indeed',
    permissions: const Permissions(),
  );
  return services;
}

void main() {
  const sizes = [
    Size(360, 640),
    Size(420, 900),
    Size(800, 600),
    Size(1100, 700),
    Size(1400, 900),
    Size(1920, 1080),
  ];

  for (final lang in ['en', 'ru']) {
    for (final theme in [ThemeMode.dark, ThemeMode.light]) {
      for (final size in sizes) {
        testWidgets('every page lays out without overflow: $lang ${theme.name} ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final services = await _services(language: lang, theme: theme);
          final s = S.forLanguage(AppLanguage.fromCode(lang));

          await tester.pumpWidget(ThelxisApp(services: services));
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text(s.t('home.yourId')), findsOneWidget);

          for (final nav in ['nav.devices', 'nav.sessions', 'nav.settings', 'nav.home']) {
            final label = s.t(nav);
            // Wide layouts list the sidebar first; on phones the bar is last
            // (the pages carry same-named headings).
            final entries = find.text(label);
            await tester.tap(
              size.width < 600
                  ? entries.last
                  : size.width < 1000
                      ? find.byTooltip(label) // the icon rail has tooltips only
                      : entries.first,
            );
            await tester.pump(const Duration(milliseconds: 50));
            await tester.pump(const Duration(milliseconds: 400));
            expect(tester.takeException(), isNull, reason: '$nav at $size');
          }
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }

  testWidgets('Russian UI is used when the language is set to ru, and the pill is localized', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = await _services(language: 'ru');
    await tester.pumpWidget(ThelxisApp(services: services));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Ваш Thelxis ID'), findsOneWidget);
    expect(find.text('Поделиться доступом'), findsOneWidget);
    // The pill on Home and the status row of the sidebar both say it.
    expect(find.text('Приём подключений недоступен'), findsWidgets);
    expect(S.current.language, AppLanguage.russian);
    await tester.pumpWidget(const SizedBox());
    S.current = S.forLanguage(AppLanguage.english);
  });

  testWidgets('switching the language in Settings updates the whole UI immediately', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = await _services();
    await tester.pumpWidget(ThelxisApp(services: services));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Settings').first);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Русский'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Настройки'), findsWidgets);
    expect(find.text('Безопасность'), findsOneWidget);
    expect(services.settings.language, 'ru');
    await tester.pumpWidget(const SizedBox());
    S.current = S.forLanguage(AppLanguage.english);
  });

  testWidgets('the wide layout shows the sidebar with labels and the brand name', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = await _services();
    await tester.pumpWidget(ThelxisApp(services: services));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Thelxis'), findsWidgets);
    expect(tester.getSize(find.byKey(const ValueKey('sidebar'))).width, 220);
    expect(find.byType(NavigationBar), findsNothing);
    for (final label in ['Home', 'Devices', 'Sessions', 'Settings']) {
      expect(find.text(label), findsWidgets);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('keyboard shortcuts switch pages and open the palette', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = await _services();
    await tester.pumpWidget(ThelxisApp(services: services));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Security'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Jump to a device'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the medium layout is a 68 px icon rail; 1000+ gets the 220 px sidebar', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = await _services();
    for (final (width, expected) in [(800.0, 68.0), (999.0, 68.0), (1000.0, 220.0)]) {
      tester.view.physicalSize = Size(width, 700);
      await tester.pumpWidget(ThelxisApp(services: services));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getSize(find.byKey(const ValueKey('sidebar'))).width, expected, reason: '$width');
      await tester.pumpWidget(const SizedBox());
    }
  });

  test('address book fixture sanity', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    expect(AddressBook(prefs).entries, isEmpty);
    expect(TrustedDevices(prefs).devices, isEmpty);
  });
}
