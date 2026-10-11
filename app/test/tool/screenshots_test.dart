// Renders the main screens to PNG files for visual review. Opt-in:
//   THELXIS_SHOTS=/some/dir flutter test test/tool/screenshots_test.dart
// Without the variable the tests are skipped, so nothing is written during a
// normal test run.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/app.dart';
import 'package:thelxis/app_services.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/system_info.dart';
import 'package:thelxis/l10n/strings.dart';
import 'package:thelxis/net/connectivity/connectivity.dart';
import 'package:thelxis/net/peer_identity.dart';
import 'package:thelxis/platform/host_platform.dart';
import 'package:thelxis/protocol/models.dart';
import 'package:thelxis/ui/home/share_access_dialog.dart';

import '../files/support/test_fonts.dart';
import '../support/fakes.dart';

final String? _out = Platform.environment['THELXIS_SHOTS'];

class NeedsPermissions extends FakeHostPlatform {
  @override
  Future<PermissionStatus> permissionStatus(HostPermission permission) async =>
      PermissionStatus.denied;
}

/// Builds the app with a realistic address book and LAN.
Future<AppServices> buildServices({
  String language = 'en',
  ThemeMode theme = ThemeMode.light,
  bool empty = false,
  bool permissions = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final identity = await Identity.fromSeed(List<int>.generate(32, (i) => i + 50));
  final connectivity = FakeConnectivity(addresses: ['192.168.1.5:47100', '[2001:db8::1]:47100']);
  final services = AppServices.create(
    prefs: prefs,
    identity: identity,
    systemInfo: const SystemInfo(
      os: 'macos',
      osVersion: '15',
      arch: 'x64',
      hostname: 'vladimirs-macbook',
      appVersion: '0.2.0',
      defaultDeviceName: 'MacBook Pro',
    ),
    connectivity: connectivity,
    platform: permissions ? NeedsPermissions() : FakeHostPlatform(),
    badge: FakeBadge(),
  );
  connectivity.publish(const ReachabilityReport(
    lanIPv4: ['192.168.1.5'],
    gatewayFound: true,
    mappingMethod: MappingMethod.upnp,
    externalIPv4: '203.0.113.7',
    externalIsPublic: true,
    listening: true,
    turnRunning: true,
  ));
  await services.settings.setLanguage(language);
  await services.settings.setThemeMode(theme);
  if (!empty) {
    Future<void> add(int seed, String name, String os, {bool fav = false, bool connected = true}) async {
      final id = await Identity.fromSeed(List<int>.filled(32, seed));
      await services.addressBook.upsertPeer(
        PeerIdentity(key: id.publicKeyB64, id: id.id, name: name, os: os, addresses: ['203.0.113.$seed:47100']),
        connected: connected,
      );
      if (fav) await services.addressBook.update(id.id, favorite: true);
    }

    await add(21, 'Office PC', 'windows', fav: true);
    await add(22, 'Mom’s iMac', 'macos');
    await add(23, 'Pixel 8', 'android');
    await add(24, 'Home server', 'linux', fav: true);
    await add(25, 'Reception laptop with a very long name indeed', 'windows', connected: false);
    for (final (seed, name, os) in [(31, 'Design Mac mini', 'macos'), (32, 'Lena’s phone', 'android')]) {
      final id = await Identity.fromSeed(List<int>.filled(32, seed));
      services.lan.debugReply(
        jsonEncode({
          't': 'here',
          'v': 2,
          'id': id.id,
          'key': id.publicKeyB64,
          'name': name,
          'os': os,
          'port': 47100,
        }),
        '192.168.1.$seed',
      );
    }
    await services.trusted.add(
      key: 'k1',
      id: 'K7M2P9XQ4TAB8HDE',
      name: 'Alice',
      permissions: const Permissions(),
    );
  }
  return services;
}

final GlobalKey shotKey = GlobalKey();

Future<void> shot(WidgetTester tester, String name) async {
  final dir = _out!;
  Directory(dir).createSync(recursive: true);
  final boundary = shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Future<void> openApp(WidgetTester tester, AppServices services, Size size) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(RepaintBoundary(key: shotKey, child: ThelxisApp(services: services)));
  // Asset images decode on real time, not on the fake clock.
  await tester.runAsync(() async {
    await precacheImage(const AssetImage('assets/icon/app_icon.png'), tester.element(find.byType(Scaffold).first));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> go(WidgetTester tester, String label) async {
  // The sidebar entry, not a same-named heading inside the page.
  await tester.tap(find.text(label).first);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 400));
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    // Icons render as boxes in tests unless the font is loaded by hand.
    final root = Platform.environment['FLUTTER_ROOT'] ?? '${Platform.environment['HOME']}/development/flutter';
    final icons = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (icons.existsSync()) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
      await loader.load();
    }
  });

  if (_out == null) {
    test('screenshots are opt-in (set THELXIS_SHOTS)', () {}, skip: 'set THELXIS_SHOTS to render');
    return;
  }

  Future<void> scenario(
    WidgetTester tester,
    String prefix,
    Size size, {
    String language = 'en',
    ThemeMode theme = ThemeMode.light,
    List<String> pages = const [],
    bool empty = false,
    bool permissions = false,
  }) async {
    final services = await buildServices(language: language, theme: theme, empty: empty, permissions: permissions);
    await openApp(tester, services, size);
    await shot(tester, '$prefix-1-home');
    final s = S.forLanguage(AppLanguage.fromCode(language));
    for (final (i, nav) in [(2, 'nav.devices'), (3, 'nav.sessions'), (4, 'nav.settings')]) {
      if (pages.isNotEmpty && !pages.contains(nav)) continue;
      await go(tester, s.t(nav));
      await shot(tester, '$prefix-$i-${nav.split('.').last}');
    }
    await tester.pumpWidget(const SizedBox());
    S.current = S.forLanguage(AppLanguage.english);
  }

  testWidgets('home light 1400', (t) async {
    await scenario(t, 'home-light-1400', const Size(1400, 900), pages: ['nav.devices', 'nav.sessions', 'nav.settings']);
  });
  testWidgets('home dark 1400', (t) async {
    await scenario(t, 'home-dark-1400', const Size(1400, 900), theme: ThemeMode.dark, pages: ['nav.settings']);
  });
  testWidgets('home light 1400 ru', (t) async {
    await scenario(t, 'home-light-1400-ru', const Size(1400, 900), language: 'ru', pages: const ['nav.settings']);
  });
  testWidgets('home dark 1400 ru', (t) async {
    await scenario(t, 'home-dark-1400-ru', const Size(1400, 900), theme: ThemeMode.dark, language: 'ru', pages: const ['none']);
  });
  testWidgets('home light 1100', (t) async {
    await scenario(t, 'home-light-1100', const Size(1100, 700), pages: const ['none']);
  });
  testWidgets('home light 800 (rail)', (t) async {
    await scenario(t, 'home-light-800', const Size(800, 600), pages: const ['none']);
  });
  testWidgets('home phone ru', (t) async {
    await scenario(t, 'phone-light-ru', const Size(390, 844), language: 'ru');
  });
  testWidgets('home phone dark en', (t) async {
    await scenario(t, 'phone-dark-en', const Size(390, 844), theme: ThemeMode.dark, pages: const ['none']);
  });
  testWidgets('home with setup needed + empty devices', (t) async {
    await scenario(t, 'home-setup-empty', const Size(1400, 900),
        empty: true, permissions: true, pages: const ['none']);
  });

  testWidgets('share dialog', (t) async {
    final services = await buildServices();
    await openApp(t, services, const Size(1100, 700));
    final ctx = t.element(find.text('Share access').first);
    showShareAccessDialog(ctx);
    await t.pump(const Duration(milliseconds: 50));
    await t.pump(const Duration(milliseconds: 500));
    await shot(t, 'dialog-share');
    await t.pumpWidget(const SizedBox());
  });
}
