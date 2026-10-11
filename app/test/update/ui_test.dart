import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/core/log.dart';
import 'package:thelxis/l10n/framework_localizations.dart';
import 'package:thelxis/ui/theme.dart';
import 'package:thelxis/ui/widgets/rows.dart';
import 'package:thelxis/update/installers/installer.dart';
import 'package:thelxis/update/ui/update_banner.dart';
import 'package:thelxis/update/ui/update_settings_section.dart';
import 'package:thelxis/update/ui/updated_toast.dart';
import 'package:thelxis/update/update_exception.dart';
import 'package:thelxis/update/update_service.dart';

import 'support/update_fakes.dart' show waitUntil;
import 'support/update_rig.dart';

Widget host(Widget child, {String language = 'en'}) => MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: Locale(language),
      supportedLocales: const [Locale('en'), Locale('ru')],
      localizationsDelegates: frameworkLocalizationsDelegates,
      home: Scaffold(body: ListView(padding: const EdgeInsets.all(16), children: [child])),
    );

const _manual = {'update.autoInstall': false};

void main() {
  setUpAll(() => Logger.sink = (level, line) {});

  // testWidgets bodies run in fake-async: anything touching the real file
  // system or timers must go through tester.runAsync.
  late UpdateRig rig;
  final rigs = <UpdateRig>[];
  tearDown(() async {
    for (final r in rigs) {
      await r.dispose();
    }
    rigs.clear();
  });

  Future<UpdateRig> make(
    WidgetTester tester, {
    String version = '0.2.0',
    bool confirm = false,
    Map<String, Object> prefsValues = const {},
    bool wrongKey = false,
  }) async {
    final made = (await tester.runAsync(
      () => UpdateRig.create(version: version, confirm: confirm, prefsValues: prefsValues, wrongKey: wrongKey),
    ))!;
    rigs.add(made);
    return made;
  }

  /// Runs real async work (checks, downloads) outside the fake-async zone.
  Future<void> run(WidgetTester tester, Future<void> Function() body) async {
    await tester.runAsync(body);
    await tester.pump();
  }

  group('UpdateBanner', () {
    testWidgets('is hidden until an update exists', (tester) async {
      rig = await make(tester, prefsValues: _manual);
      await tester.pumpWidget(host(UpdateBanner(service: rig.service)));
      expect(find.byType(FilledButton), findsNothing);
      expect(find.textContaining('0.2.0'), findsNothing);

      await run(tester, rig.service.checkNow);
      await tester.pumpAndSettle();
      expect(find.text('Version 0.2.0 is available'), findsOneWidget);
      expect(find.text('Update'), findsOneWidget);
      expect(find.byKey(const ValueKey('update-dismiss')), findsOneWidget, reason: 'the banner can be closed');
      expect(find.text("What's new"), findsOneWidget);
    });

    testWidgets('speaks Russian for ru locales', (tester) async {
      rig = await make(tester, prefsValues: _manual);
      await tester.pumpWidget(host(UpdateBanner(service: rig.service), language: 'ru'));
      await run(tester, rig.service.checkNow);
      await tester.pumpAndSettle();

      expect(find.text('Доступна версия 0.2.0'), findsOneWidget);
      expect(find.text('Обновить'), findsOneWidget);
      expect(find.byTooltip('Скрыть'), findsOneWidget);
    });

    testWidgets('closing the banner hides it and remembers the version', (tester) async {
      rig = await make(tester, prefsValues: _manual);
      await tester.pumpWidget(host(UpdateBanner(service: rig.service)));
      await run(tester, rig.service.checkNow);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('update-dismiss')));
      await tester.pumpAndSettle();
      expect(find.text('Version 0.2.0 is available'), findsNothing);
      expect(rig.service.skippedVersion, '0.2.0');
    });

    testWidgets('Update downloads and installs', (tester) async {
      rig = await make(tester, prefsValues: _manual);
      await tester.pumpWidget(host(UpdateBanner(service: rig.service)));
      await run(tester, rig.service.checkNow);
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        await tester.tap(find.text('Update'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(rig.installer.installed, hasLength(1));
    });

    testWidgets('shows download progress with a cancel button', (tester) async {
      rig = await make(tester, prefsValues: _manual);
      rig.downloader.gate = Completer<void>();
      await tester.pumpWidget(host(UpdateBanner(service: rig.service)));
      await run(tester, rig.service.checkNow);

      late Future<void> download;
      await tester.runAsync(() async {
        download = rig.service.downloadAndInstall();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Downloading version 0.2.0'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
      expect(bar.value, closeTo(0.5, 0.01));
      expect(find.text('Cancel'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.text('Cancel'));
        await download;
      });
      await tester.pumpAndSettle();
      expect(find.text('Version 0.2.0 is available'), findsOneWidget);
    });

    testWidgets('tells the user the install waits for the session to end', (tester) async {
      rig = await make(tester);
      rig.busy = true;
      await tester.pumpWidget(host(UpdateBanner(service: rig.service)));
      await run(tester, rig.service.checkNow);
      await tester.runAsync(() => waitUntil(() => rig.service.waitingForIdle));
      await tester.pumpAndSettle();

      expect(find.text('Will install after the session ends'), findsOneWidget);
      expect(find.text('Version 0.2.0 is ready to install'), findsOneWidget);
      expect(rig.installer.installed, isEmpty);
    });

    testWidgets('asks for "Install now" where the OS shows a prompt', (tester) async {
      rig = await make(tester, confirm: true);
      await tester.pumpWidget(host(UpdateBanner(service: rig.service)));
      await run(tester, rig.service.checkNow);
      await tester.runAsync(() => waitUntil(() => rig.service.state == UpdateState.ready));
      await tester.pumpAndSettle();

      expect(find.text('Install now'), findsOneWidget);
      expect(find.text('The system will ask you to confirm the installation.'), findsOneWidget);
    });

    testWidgets('manual install and download errors are explained', (tester) async {
      rig = await make(tester, confirm: true, prefsValues: _manual);
      rig.installer.script
        ..clear()
        ..add(const InstallResult.manual(ManualInstallReason.installPermission));
      await tester.pumpWidget(host(UpdateBanner(service: rig.service)));
      await run(tester, rig.service.checkNow);
      await run(tester, rig.service.downloadAndInstall);
      await tester.pumpAndSettle();
      expect(find.text('Finish the installation'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
      await tester.runAsync(rig.dispose);
      rigs.remove(rig);

      rig = await make(tester, prefsValues: _manual);
      rig.downloader.downloadFailure = const UpdateException(UpdateErrorKind.hash, 'x');
      await tester.pumpWidget(host(UpdateBanner(service: rig.service)));
      await run(tester, rig.service.checkNow);
      await run(tester, rig.service.downloadAndInstall);
      await tester.pumpAndSettle();
      expect(find.text('Update failed'), findsOneWidget);
      expect(find.text('The downloaded file failed the integrity check and was deleted.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('a failed check does not show a banner', (tester) async {
      rig = await make(tester, wrongKey: true);
      await tester.pumpWidget(host(UpdateBanner(service: rig.service)));
      await run(tester, rig.service.checkNow);
      await tester.pumpAndSettle();
      expect(rig.service.state, UpdateState.error);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('fits a 320 px wide phone in Russian without overflow', (tester) async {
      rig = await make(tester, confirm: true);
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host(UpdateBanner(service: rig.service), language: 'ru'));
      await run(tester, rig.service.checkNow);
      await tester.runAsync(() => waitUntil(() => rig.service.state == UpdateState.ready));
      await tester.pumpAndSettle();

      expect(find.text('Установить сейчас'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('UpdateSettingsSection', () {
    testWidgets('shows version and status, checks on demand and edits the switches', (tester) async {
      rig = await make(tester, version: '0.1.0');
      await tester.pumpWidget(host(UpdateSettingsSection(service: rig.service)));
      await run(tester, rig.service.start);
      await tester.pump();

      expect(find.text('Version 0.1.0'), findsOneWidget);
      expect(find.text('Not checked yet'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.text('Check now'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(rig.manifestFetches, 1);
      expect(find.textContaining('You have the latest version'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.text('Check for updates automatically'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(rig.service.autoCheck, isFalse);
      expect(rig.prefs.getBool('update.autoCheck'), isFalse);

      // "Install automatically" is meaningless without automatic checks.
      final installSwitch = tester.widget<SwitchRow>(
        find.widgetWithText(SwitchRow, 'Install automatically'),
      );
      expect(installSwitch.onChanged, isNull);
    });

    testWidgets('shows the error of a failed check and an Update button for a new version', (tester) async {
      rig = await make(tester, wrongKey: true);
      await tester.pumpWidget(host(UpdateSettingsSection(service: rig.service), language: 'ru'));
      await run(tester, rig.service.checkNow);
      await tester.pumpAndSettle();
      expect(find.text('Подпись обновления недействительна, поэтому оно отклонено.'), findsOneWidget);
      await tester.runAsync(rig.dispose);
      rigs.remove(rig);

      rig = await make(tester, prefsValues: _manual);
      await tester.pumpWidget(host(UpdateSettingsSection(service: rig.service)));
      await run(tester, rig.service.checkNow);
      await tester.pumpAndSettle();
      expect(find.text('Version 0.2.0 is available'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Update'), findsOneWidget);
    });

    testWidgets('can be embedded without its own card', (tester) async {
      rig = await make(tester);
      await tester.pumpWidget(host(UpdateSettingsSection(service: rig.service, card: false)));
      expect(find.byType(Card), findsNothing);
      expect(find.text('Release notes'), findsOneWidget);
    });
  });

  testWidgets('showUpdatedToast announces the new version', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(onPressed: () => showUpdatedToast(context, '0.2.0'), child: const Text('go')),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Thelxis was updated to version 0.2.0'), findsOneWidget);
    expect(find.text("What's new"), findsOneWidget);
  });

  group('the "updated" toast can always be dismissed', () {
    Future<void> show(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () => showUpdatedToast(context, '0.2.0'), child: const Text('go')),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('it has a close button', (tester) async {
      await show(tester);
      expect(find.byIcon(Icons.close), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Thelxis was updated to version 0.2.0'), findsNothing);
    });

    testWidgets('and goes away by itself even though it carries an action', (tester) async {
      await show(tester);
      await tester.pump(const Duration(seconds: 9));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Thelxis was updated to version 0.2.0'), findsNothing);
    });
  });
}
