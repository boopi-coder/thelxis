import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/app.dart';
import 'package:thelxis/app_services.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/system_info.dart';
import 'package:thelxis/desktop/desktop_integration.dart';
import 'package:thelxis/l10n/strings.dart';
import 'package:thelxis/net/net_address.dart';
import 'package:thelxis/net/peer_identity.dart';
import 'package:thelxis/protocol/models.dart';
import 'package:thelxis/session/prompts.dart';

import 'support/fakes.dart';

class _RecordingDesktop extends NoopDesktop {
  final List<(TrayMenuLabels, bool)> menus = [];
  final List<String> tooltips = [];
  int fronts = 0;

  @override
  bool get isDesktop => true;

  @override
  Future<void> updateTrayMenu(TrayMenuLabels labels, {required bool allowIncoming}) async {
    menus.add((labels, allowIncoming));
  }

  @override
  Future<void> setTrayStatus(String text) async => tooltips.add(text);

  @override
  Future<void> bringToFront() async => fronts++;
}

const _peer = PeerIdentity(
  key: 'k',
  id: 'K7M2P9XQ4TAB8HDE',
  name: 'Alice MacBook',
  os: 'macos',
);

Future<AppServices> _services({DesktopIntegration? desktop}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return AppServices.create(
    prefs: prefs,
    identity: await Identity.fromSeed(List<int>.generate(32, (i) => i + 70)),
    systemInfo: SystemInfo.fallback(),
    connectivity: FakeConnectivity(),
    platform: FakeHostPlatform(),
    badge: FakeBadge(),
    desktop: desktop,
  );
}

void main() {
  Future<AppServices> boot(WidgetTester tester, {DesktopIntegration? desktop}) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = await _services(desktop: desktop);
    await tester.pumpWidget(ThelxisApp(services: services));
    await tester.pump(const Duration(milliseconds: 300));
    return services;
  }

  testWidgets('the accept prompt shows the verified peer, honours the toggles and returns them', (tester) async {
    final services = await boot(tester);
    final prompt = AcceptRequestPrompt(
      peer: _peer,
      claimedUser: 'Alice',
      proposed: const Permissions(),
      canControl: true,
    );
    final future = services.sessions.prompts.push(prompt);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Alice wants to connect'), findsOneWidget);
    expect(find.text('Alice MacBook'), findsOneWidget);
    expect(find.text('K7M2-P9XQ-4TAB-8HDE'), findsOneWidget);
    expect(find.text('Transfer files'), findsOneWidget, reason: 'files permission toggle');
    expect(find.text('Always allow this device'), findsOneWidget);

    await tester.tap(find.text('Transfer files'));
    await tester.tap(find.text('Always allow this device'));
    await tester.pump();
    await tester.tap(find.text('Accept'));
    await tester.pump();
    final result = await future;
    expect(result.accepted, isTrue);
    expect(result.alwaysAllow, isTrue);
    expect(result.permissions, const Permissions(files: false));

    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Alice wants to connect'), findsNothing, reason: 'the dialog closes itself');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Deny returns a refusal', (tester) async {
    final services = await boot(tester);
    final future = services.sessions.prompts.push(AcceptRequestPrompt(
      peer: _peer,
      claimedUser: '',
      proposed: const Permissions(),
      canControl: false,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Alice MacBook wants to connect'), findsOneWidget);
    await tester.tap(find.text('Deny'));
    await tester.pump();
    expect((await future).accepted, isFalse);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a prompt that is answered elsewhere (timeout) closes its dialog', (tester) async {
    final services = await boot(tester);
    final prompt = AcceptRequestPrompt(
      peer: _peer,
      claimedUser: 'Alice',
      proposed: const Permissions(),
      canControl: true,
    );
    unawaited(services.sessions.prompts.push(prompt));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Alice wants to connect'), findsOneWidget);
    prompt.resolve(ApprovalResult.denied);
    await tester.pumpAndSettle();
    expect(find.text('Alice wants to connect'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('prompts queue and appear one after another', (tester) async {
    final services = await boot(tester);
    final first = WarningPrompt(title: 'First warning', message: 'm1');
    final second = WarningPrompt(title: 'Second warning', message: 'm2');
    unawaited(services.sessions.prompts.push(first));
    unawaited(services.sessions.prompts.push(second));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('First warning'), findsOneWidget);
    expect(find.text('Second warning'), findsNothing);
    await tester.tap(find.text('OK'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Second warning'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('first contact shows the ID and returns the decision', (tester) async {
    final services = await boot(tester);
    final future = services.sessions.prompts.push(FirstContactPrompt(peer: _peer, address: NetAddress('203.0.113.5', 47100)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Connect to a new device?'), findsOneWidget);
    expect(find.text('Found at 203.0.113.5:47100'), findsOneWidget);
    await tester.tap(find.text('Trust and connect'));
    await tester.pump();
    expect(await future, isTrue);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reverse offers are localized', (tester) async {
    final services = await boot(tester);
    await services.settings.setLanguage('ru');
    await tester.pump(const Duration(milliseconds: 300));
    final future = services.sessions.prompts.push(ReverseOfferPrompt(peer: _peer));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Alice MacBook предлагает вам управлять своим компьютером'), findsOneWidget);
    await tester.tap(find.text('Отказаться'));
    await tester.pump();
    expect(await future, isFalse);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox());
    S.current = S.forLanguage(AppLanguage.english);
  });

  testWidgets('the tray menu follows the language and the Allow-incoming setting', (tester) async {
    final desktop = _RecordingDesktop();
    final services = await boot(tester, desktop: desktop);
    await tester.pump(const Duration(milliseconds: 100));
    expect(desktop.menus.last.$1.open, 'Open Thelxis');
    expect(desktop.menus.last.$2, isTrue);

    await services.settings.setAllowIncoming(false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(desktop.menus.last.$2, isFalse);

    await services.settings.setLanguage('ru');
    await tester.pump(const Duration(milliseconds: 100));
    expect(desktop.menus.last.$1.open, 'Открыть Thelxis');
    expect(desktop.menus.last.$1.quit, 'Выйти');
    expect(desktop.menus.last.$1.allowIncoming, 'Разрешить входящие подключения');
    await tester.pumpWidget(const SizedBox());
    S.current = S.forLanguage(AppLanguage.english);
  });
}
