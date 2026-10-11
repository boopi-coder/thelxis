import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/app.dart';
import 'package:thelxis/app_services.dart';
import 'package:thelxis/core/address_book.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/log.dart';
import 'package:thelxis/core/settings.dart';
import 'package:thelxis/core/system_info.dart';
import 'package:thelxis/core/trusted_devices.dart';
import 'package:thelxis/l10n/strings.dart';
import 'package:thelxis/net/connectivity/connectivity.dart';
import 'package:thelxis/net/discovery.dart';
import 'package:thelxis/net/peer_identity.dart';
import 'package:thelxis/session/host_credentials.dart';
import 'package:thelxis/session/session_history.dart';
import 'package:thelxis/session/session_manager.dart';
import 'package:thelxis/ui/home/diagnostics_screen.dart';
import 'package:thelxis/ui/home/reachability.dart';
import 'package:thelxis/ui/home/reachability_advice.dart';
import 'package:thelxis/ui/settings/manual_forwarding_section.dart';
import 'package:thelxis/ui/widgets/common.dart';

import 'support/fakes.dart';

const _mapping = PortMapping(
  protocol: MappingProtocol.tcp,
  internalPort: 47100,
  externalPort: 47100,
  method: MappingMethod.natPmp,
);

ReachabilityReport _report({
  bool listening = true,
  bool gateway = false,
  String? external,
  bool public = false,
  bool direct = false,
  bool manual = false,
  bool cgnat = false,
  List<String> v6 = const [],
  List<PortMapping> mappings = const [],
  List<String> lan = const ['192.168.1.5'],
}) =>
    ReachabilityReport(
      lanIPv4: lan,
      globalIPv6: v6,
      gatewayFound: gateway,
      externalIPv4: external,
      externalIsPublic: public,
      externalIsDirect: direct,
      manualForwarding: manual,
      cgnat: cgnat,
      mappings: mappings,
      listening: listening,
      mappingMethod: mappings.isEmpty ? null : mappings.first.method,
    );

Future<(AppServices, FakeConnectivity)> _services() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final net = FakeConnectivity(addresses: ['192.168.1.5:47100']);
  final services = AppServices.create(
    prefs: prefs,
    identity: await Identity.fromSeed(List<int>.generate(32, (i) => i + 9)),
    systemInfo: const SystemInfo(
      os: 'linux',
      osVersion: 'test',
      arch: 'x64',
      hostname: 'test-host',
      appVersion: '0.1.1',
      defaultDeviceName: 'Test Machine',
    ),
    connectivity: net,
    platform: FakeHostPlatform(),
    badge: FakeBadge(),
  );
  return (services, net);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Logger.sink = (_, _) {};

  group('advice classification', () {
    ReachKind kind(ReachabilityReport r, {bool incoming = true, bool upnp = true}) =>
        adviseReachability(allowIncoming: incoming, report: r, upnpEnabled: upnp).kind;

    test('every situation maps to its own advice', () {
      expect(kind(_report(), incoming: false), ReachKind.off);
      expect(kind(_report(listening: false)), ReachKind.portInUse);
      expect(kind(_report(public: true, direct: true, external: '203.0.113.9')), ReachKind.direct);
      expect(kind(_report(public: true, gateway: true, external: '203.0.113.9', mappings: [_mapping])), ReachKind.mapped);
      expect(kind(_report(manual: true)), ReachKind.manual);
      expect(kind(_report(v6: ['2001:db8::1'])), ReachKind.ipv6);
      expect(kind(_report(gateway: true, cgnat: true, external: '100.72.1.9')), ReachKind.cgnat);
      expect(kind(_report(cgnat: true)), ReachKind.cgnat, reason: 'unknown WAN address: assume the provider');
      for (final ip in ['192.168.0.2', '10.1.2.3', '172.20.0.5']) {
        expect(kind(_report(gateway: true, cgnat: true, external: ip)), ReachKind.doubleNat, reason: ip);
      }
      expect(kind(_report(gateway: true, public: true, external: '203.0.113.9')), ReachKind.mappingFailed);
      expect(kind(_report(), upnp: false), ReachKind.mappingOff);
      expect(kind(_report()), ReachKind.noRouter);
    });

    test('IPv6 reachability does not hide a CGNAT, but IPv4 reachability wins over IPv6', () {
      expect(kind(_report(cgnat: true, v6: ['2001:db8::1'], external: '100.64.0.9')), ReachKind.ipv6);
      expect(
        kind(_report(public: true, external: '203.0.113.9', mappings: [_mapping], v6: ['2001:db8::1'])),
        ReachKind.mapped,
      );
    });

    test('the mapping method is named, and only reachable cases are green', () {
      final a = adviseReachability(
        allowIncoming: true,
        report: _report(public: true, external: '203.0.113.9', mappings: [_mapping]),
      );
      expect(a.title(S.forLanguage(AppLanguage.english)), 'Reachable via your router (NAT-PMP)');
      for (final k in ReachKind.values) {
        final adv = ReachAdvice(k);
        expect(adv.tone == PillTone.good, adv.reachable, reason: '$k');
      }
    });

    test('every case has complete English and Russian text, steps and an action where something is wrong', () {
      final cyr = RegExp('[А-Яа-яЁё]');
      for (final lang in AppLanguage.values) {
        final s = S.forLanguage(lang);
        for (final k in ReachKind.values) {
          final a = ReachAdvice(k, method: 'UPnP');
          expect(a.title(s), isNotEmpty, reason: '$k');
          expect(a.body(s), isNotEmpty, reason: '$k');
          expect(a.label(s), isNotEmpty, reason: '$k');
          expect(a.steps(s).every((x) => x.trim().isNotEmpty), isTrue, reason: '$k');
          if (lang == AppLanguage.russian) expect(cyr.hasMatch(a.title(s)), isTrue, reason: '$k');
          if (!a.reachable && k != ReachKind.off) {
            expect(a.hint(s), isNotNull, reason: '$k has a Home hint');
            expect(a.actions, isNotEmpty, reason: '$k offers something to do');
            expect(a.steps(s), isNotEmpty, reason: '$k');
          } else {
            expect(a.hint(s), isNull, reason: '$k needs no Home hint');
          }
        }
      }
    });

    test('CGNAT advice names the ways around it', () {
      final en = S.forLanguage(AppLanguage.english);
      final steps = const ReachAdvice(ReachKind.cgnat).steps(en).join('\n');
      expect(steps, allOf(contains('Connect by code'), contains('0.2'), contains('Let them control this device'), contains('IPv6')));
      final ru = S.forLanguage(AppLanguage.russian);
      final stepsRu = const ReachAdvice(ReachKind.cgnat).steps(ru).join('\n');
      expect(stepsRu, allOf(contains('по коду'), contains('IPv6')));
    });

    test('the pill summary follows the advice', () {
      final s = S.forLanguage(AppLanguage.english);
      final lan = summarizeReachability(allowIncoming: true, report: _report(), strings: s);
      expect((lan.label, lan.tone), ('LAN only', PillTone.warn));
      final off = summarizeReachability(allowIncoming: true, report: _report(), upnpEnabled: false, strings: s);
      expect(off.detail, contains('Without it'));
    });
  });

  group('manual forwarding instructions', () {
    test('spell out the three router rules in both languages', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = AppSettings(await SharedPreferences.getInstance(), defaultDeviceName: 'x');
      await settings.setManualForwardingDetails(signalingTcp: 50000, turnUdp: 50001, turnTcp: 50002);
      expect(
        manualForwardingInstructions(S.forLanguage(AppLanguage.english), settings, '192.168.1.5'),
        'On the router, forward TCP 50000 → 192.168.1.5:47100, UDP 50001 → 192.168.1.5:47100, TCP 50002 → 192.168.1.5:47101.',
      );
      expect(
        manualForwardingInstructions(S.forLanguage(AppLanguage.russian), settings, '10.0.0.7'),
        'На роутере пробросьте TCP 50000 → 10.0.0.7:47100, UDP 50001 → 10.0.0.7:47100, TCP 50002 → 10.0.0.7:47101.',
      );
      expect(manualForwardingInstructions(S.forLanguage(AppLanguage.english), settings, null), contains('<LAN IP of this computer>:47100'));
    });
  });

  group('session manager', () {
    test('hands manual forwarding to the connectivity module at start and on every real change', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = AppSettings(prefs, defaultDeviceName: 'Host');
      await settings.setAllowIncoming(false); // no sockets in this test
      final identity = await Identity.fromSeed(List<int>.filled(32, 33));
      final net = FakeConnectivity();
      final manager = SessionManager(
        settings: settings,
        identity: identity,
        systemInfo: SystemInfo.fallback(),
        trusted: TrustedDevices(prefs),
        addressBook: AddressBook(prefs),
        credentials: HostCredentials(identity: identity, settings: settings),
        connectivity: net,
        platform: FakeHostPlatform(),
        lan: LanDiscovery(
          identity: identity,
          localInfo: () => const LocalPeerInfo(name: 'x', os: 'linux', app: '0'),
          signalingPort: () => 0,
        ),
        history: SessionHistory(settings),
        badge: FakeBadge(),
        listenerPort: 0,
      );
      addTearDown(manager.dispose);

      await manager.start();
      expect(net.manualHistory, [null], reason: 'cleared at start so nothing stale is advertised');

      await settings.setManualForwardingEnabled(true);
      await settings.setManualForwardingDetails(host: 'home.example.org', signalingTcp: 50000, turnUdp: 50001, turnTcp: 50002);
      await manager.applySettings();
      final f = net.manualForwarding!;
      expect((f.externalHost, f.signalingTcp, f.turnUdp, f.turnTcp), ('home.example.org', 50000, 50001, 50002));

      final calls = net.manualHistory.length;
      await settings.setDeviceName('Renamed'); // unrelated change: no new call
      await manager.applySettings();
      expect(net.manualHistory, hasLength(calls));

      await settings.setManualForwardingEnabled(false);
      await manager.applySettings();
      expect(net.manualForwarding, isNull);
      expect(net.manualHistory.length, calls + 1);
    });
  });

  group('Home and diagnostics', () {
    Future<(AppServices, FakeConnectivity)> pump(WidgetTester tester, {Size size = const Size(1200, 1000)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (services, net) = (await tester.runAsync(_services))!;
      await tester.pumpWidget(ThelxisApp(services: services));
      await tester.pump(const Duration(milliseconds: 300));
      return (services, net);
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('a CGNAT shows a hint under the pill; tapping it opens the plain-language advice', (tester) async {
      final (_, net) = await pump(tester);
      net.publish(_report(gateway: true, cgnat: true, external: '100.72.1.9'));
      await tester.pump();
      expect(find.text('LAN only'), findsOneWidget);
      expect(find.text('Your provider blocks incoming (CGNAT). Tap for options.'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('reach-hint')));
      await settle(tester);
      expect(find.text('Your provider blocks incoming connections'), findsOneWidget);
      expect(find.textContaining('Connect by code (coming in version 0.2)'), findsOneWidget);
      expect(find.textContaining('Let them control this device'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tapping the pill opens the diagnostics with the advice at the top', (tester) async {
      final (_, net) = await pump(tester);
      net.publish(_report());
      await tester.pump();
      await tester.tap(find.text('LAN only'));
      await settle(tester);
      expect(find.byKey(const ValueKey('reach-advice')), findsOneWidget);
      expect(find.text('Reachable only inside your network'), findsOneWidget);
      expect(find.textContaining('Enable UPnP on the router'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('reachable situations show a green status and no hint', (tester) async {
      final (_, net) = await pump(tester);
      net.publish(_report(public: true, gateway: true, external: '203.0.113.9', mappings: [_mapping]));
      await tester.pump();
      expect(find.text('Reachable from internet'), findsOneWidget);
      expect(find.byKey(const ValueKey('reach-hint')), findsNothing);

      await tester.tap(find.text('Reachable from internet'));
      await settle(tester);
      expect(find.text('Reachable via your router (NAT-PMP)'), findsOneWidget);
      expect(find.text('What you can do'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the hint follows the situation and disappears once the problem is gone', (tester) async {
      final (_, net) = await pump(tester);
      net.publish(_report(gateway: true, public: true, external: '203.0.113.9'));
      await tester.pump();
      expect(find.text('The router did not open the ports. Tap to fix.'), findsOneWidget);
      net.publish(_report(gateway: true, cgnat: true, external: '192.168.0.2'));
      await tester.pump();
      expect(find.text('Two routers in a row (double NAT). Tap for options.'), findsOneWidget);
      net.publish(_report(v6: ['2001:db8::1']));
      await tester.pump();
      expect(find.byKey(const ValueKey('reach-hint')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('advice buttons act: turn on mapping, jump to manual forwarding, re-scan', (tester) async {
      final (services, net) = await pump(tester, size: const Size(1200, 4200));
      await services.settings.setUpnp(false);
      net.publish(_report());
      await tester.pump();
      await tester.tap(find.text('LAN only'));
      await settle(tester);
      expect(find.text('Automatic port mapping is off'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('reach-action-enableMapping')));
      await tester.pump();
      expect(services.settings.upnp, isTrue);
      expect(find.text('Reachable only inside your network'), findsOneWidget, reason: 'advice re-evaluates');

      await tester.tap(find.byKey(const ValueKey('reach-action-manualForwarding')));
      await settle(tester);
      expect(find.text('CONNECTIVITY'), findsOneWidget, reason: 'lands on Settings');
      expect(find.byKey(const ValueKey('manual-fwd-switch')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Russian advice', (tester) async {
      final (services, net) = await pump(tester);
      await services.settings.setLanguage('ru');
      net.publish(_report(gateway: true, cgnat: true, external: '100.72.1.9'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Провайдер блокирует входящие (CGNAT). Нажмите, чтобы увидеть варианты.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reach-hint')));
      await settle(tester);
      expect(find.text('Провайдер блокирует входящие подключения'), findsOneWidget);
      expect(find.textContaining('Подключение по коду'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('layout', () {
    final situations = <ReachabilityReport>[
      _report(),
      _report(listening: false),
      _report(public: true, direct: true, external: '203.0.113.9'),
      _report(public: true, gateway: true, external: '203.0.113.9', mappings: [_mapping]),
      _report(manual: true),
      _report(v6: ['2001:db8:1234:5678:9abc:def0:1234:5678']),
      _report(gateway: true, cgnat: true, external: '100.72.1.9'),
      _report(gateway: true, cgnat: true, external: '192.168.0.2'),
      _report(gateway: true, public: true, external: '203.0.113.9'),
    ];

    for (final lang in ['en', 'ru']) {
      for (final size in const [Size(320, 640), Size(420, 900), Size(1200, 900)]) {
        testWidgets('diagnostics advice and Home hint do not overflow: $lang ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final (services, net) = (await tester.runAsync(_services))!;
          await services.settings.setLanguage(lang);
          await tester.pumpWidget(ThelxisApp(services: services));
          await tester.pump(const Duration(milliseconds: 300));
          final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
          for (final r in situations) {
            net.publish(r);
            await tester.pump();
            expect(tester.takeException(), isNull, reason: 'Home with $r');
          }
          nav.push(MaterialPageRoute<void>(builder: (_) => const DiagnosticsScreen()));
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump(const Duration(milliseconds: 500));
          for (final r in situations) {
            net.publish(r);
            await tester.pump();
            expect(find.byKey(const ValueKey('reach-advice')), findsOneWidget);
            expect(tester.takeException(), isNull, reason: 'diagnostics with $r');
          }
          await services.settings.setUpnp(false);
          net.publish(_report());
          await tester.pump();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          S.current = S.forLanguage(AppLanguage.english);
        });
      }
    }
  });

  group('Settings -> Manual port forwarding', () {
    String? clipboard;
    setUp(() {
      clipboard = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String?;
          return null;
        },
      );
    });

    Future<(AppServices, FakeConnectivity)> openSettings(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 4200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (services, net) = (await tester.runAsync(_services))!;
      await tester.pumpWidget(ThelxisApp(services: services));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Settings').first);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));
      return (services, net);
    }

    Finder field(String key) => find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(TextField));

    testWidgets('public STUN is on by default and explains what it reveals', (tester) async {
      final (services, _) = await openSettings(tester);
      expect(services.settings.publicStun, isTrue);
      final tile = tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Use public STUN servers'));
      expect(tile.value, isTrue);
      expect(find.textContaining('never see your screen, files or any other data'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the toggle reveals the host, the three ports and the instructions; edits are saved', (tester) async {
      final (services, net) = await openSettings(tester);
      net.publish(_report());
      await tester.pump();
      expect(find.byKey(const ValueKey('manual-fwd-tcp')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('manual-fwd-switch')));
      await tester.pump();
      expect(services.settings.manualForwardingEnabled, isTrue);
      expect(tester.widget<TextField>(field('manual-fwd-tcp')).controller!.text, '47100');
      expect(tester.widget<TextField>(field('manual-fwd-udp')).controller!.text, '47100');
      expect(tester.widget<TextField>(field('manual-fwd-turn-tcp')).controller!.text, '47101');
      expect(
        tester.widget<SelectableText>(find.byKey(const ValueKey('manual-fwd-instructions'))).data,
        'On the router, forward TCP 47100 → 192.168.1.5:47100, UDP 47100 → 192.168.1.5:47100, TCP 47101 → 192.168.1.5:47101.',
      );

      await tester.enterText(field('manual-fwd-tcp'), '50000');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.enterText(field('manual-fwd-host'), 'home.example.org');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(services.settings.manualSignalingPort, 50000);
      expect(services.settings.manualForwardHost, 'home.example.org');
      expect(find.textContaining('forward TCP 50000 → 192.168.1.5:47100'), findsOneWidget);

      // The session manager passes it on to the connectivity module.
      await tester.runAsync(services.sessions.applySettings);
      final f = net.manualForwarding!;
      expect((f.externalHost, f.signalingTcp, f.turnUdp, f.turnTcp), ('home.example.org', 50000, 47100, 47101));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('invalid ports and hosts are flagged and not saved', (tester) async {
      final (services, _) = await openSettings(tester);
      await tester.tap(find.byKey(const ValueKey('manual-fwd-switch')));
      await tester.pump();

      await tester.enterText(field('manual-fwd-udp'), '0');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('A port from 1 to 65535'), findsOneWidget);
      expect(services.settings.manualTurnUdpPort, 47100);

      await tester.enterText(field('manual-fwd-host'), 'bad host!');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('Enter an IP address or a host name'), findsOneWidget);
      expect(services.settings.manualForwardHost, isEmpty);

      await tester.enterText(field('manual-fwd-udp'), '65535');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('A port from 1 to 65535'), findsNothing);
      expect(services.settings.manualTurnUdpPort, 65535);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the copy button puts the instructions on the clipboard', (tester) async {
      final (_, net) = await openSettings(tester);
      net.publish(_report(lan: ['10.0.0.7']));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('manual-fwd-switch')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('manual-fwd-copy')));
      await tester.pump();
      expect(
        clipboard,
        'On the router, forward TCP 47100 → 10.0.0.7:47100, UDP 47100 → 10.0.0.7:47100, TCP 47101 → 10.0.0.7:47101.',
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the section fits a narrow phone in Russian', (tester) async {
      tester.view.physicalSize = const Size(360, 4200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (services, _) = (await tester.runAsync(_services))!;
      await services.settings.setLanguage('ru');
      await services.settings.setManualForwardingEnabled(true);
      await tester.pumpWidget(ThelxisApp(services: services));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Настройки').first);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('manual-fwd-udp')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
