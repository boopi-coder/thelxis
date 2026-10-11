import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart' show CupertinoLocalizations, DefaultCupertinoLocalizations;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/files/file_transfer_endpoint.dart';
import 'package:thelxis/files/ui/file_drop_target.dart';
import 'package:thelxis/files/ui/file_icons.dart';
import 'package:thelxis/files/ui/file_transfer_panel.dart';
import 'package:thelxis/files/ui/files_format.dart';
import 'package:thelxis/files/ui/files_strings.dart';

import 'support/rig.dart';
import 'support/test_fonts.dart';

Widget host(Widget child, {Locale locale = const Locale('en'), ThemeMode mode = ThemeMode.light}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: const [Locale('en'), Locale('ru')],
    localizationsDelegates: const [_AnyLocaleWidgets(), _AnyLocaleMaterial(), _AnyLocaleCupertino()],
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF6C4CF5), fontFamily: 'Roboto'),
    darkTheme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF6C4CF5), brightness: Brightness.dark, fontFamily: 'Roboto'),
    themeMode: mode,
    home: Scaffold(body: Align(alignment: Alignment.topLeft, child: SizedBox(width: 420, child: child))),
  );
}

/// flutter_localizations is not a dependency; English strings for any locale
/// are enough because the module brings its own translations.
class _AnyLocaleMaterial extends LocalizationsDelegate<MaterialLocalizations> {
  const _AnyLocaleMaterial();
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<MaterialLocalizations> load(Locale locale) => DefaultMaterialLocalizations.load(locale);
  @override
  bool shouldReload(covariant LocalizationsDelegate<MaterialLocalizations> old) => false;
}

class _AnyLocaleWidgets extends LocalizationsDelegate<WidgetsLocalizations> {
  const _AnyLocaleWidgets();
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<WidgetsLocalizations> load(Locale locale) => DefaultWidgetsLocalizations.load(locale);
  @override
  bool shouldReload(covariant LocalizationsDelegate<WidgetsLocalizations> old) => false;
}

class _AnyLocaleCupertino extends LocalizationsDelegate<CupertinoLocalizations> {
  const _AnyLocaleCupertino();
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<CupertinoLocalizations> load(Locale locale) => DefaultCupertinoLocalizations.load(locale);
  @override
  bool shouldReload(covariant LocalizationsDelegate<CupertinoLocalizations> old) => false;
}

/// The endpoint runs on the real event loop while widgets run in fake time, so
/// alternate between letting real I/O make progress and pumping frames until
/// [until] holds (or a fixed number of rounds passed).
Future<void> settle(WidgetTester tester, {bool Function()? until, int rounds = 10}) async {
  final limit = until == null ? rounds : 400;
  for (var i = 0; i < limit; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
    await tester.pump(const Duration(milliseconds: 40));
    if (until != null && until()) {
      await tester.pump(const Duration(milliseconds: 40));
      return;
    }
  }
  if (until != null) fail('condition not reached while pumping');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadTestFonts);

  group('FilesStrings', () {
    test('Russian for ru, English for everything else', () {
      expect(FilesStrings.forLanguage('ru').panelTitle, 'Файлы');
      expect(FilesStrings.forLanguage('en').panelTitle, 'Files');
      expect(FilesStrings.forLanguage('de').panelTitle, 'Files');
    });

    test('Russian plurals', () {
      final s = FilesStrings.forLanguage('ru');
      expect(s.itemsCount(1), '1 элемент');
      expect(s.itemsCount(2), '2 элемента');
      expect(s.itemsCount(5), '5 элементов');
      expect(s.itemsCount(11), '11 элементов');
      expect(s.itemsCount(21), '21 элемент');
      expect(s.itemsCount(112), '112 элементов');
    });

    test('every transfer status and error has text in both languages', () {
      for (final lang in ['en', 'ru']) {
        final s = FilesStrings.forLanguage(lang);
        for (final status in TransferStatus.values) {
          for (final dir in TransferDirection.values) {
            final t = Transfer(xid: 1, direction: dir, name: 'a', size: 1)..status = status;
            expect(s.statusLabel(t), isNotEmpty);
          }
        }
        for (final e in [...TransferError.values, null]) {
          expect(s.errorLabel(e), isNotEmpty);
        }
        for (final k in RemoteFsErrorKind.values) {
          expect(s.remoteError(k), isNotEmpty);
        }
      }
    });
  });

  group('formatting', () {
    final en = FilesStrings.forLanguage('en');
    final ru = FilesStrings.forLanguage('ru');

    test('bytes', () {
      expect(formatBytes(0, en), '0 B');
      expect(formatBytes(1023, en), '1023 B');
      expect(formatBytes(1536, en), '1.5 KB');
      expect(formatBytes(5 * 1024 * 1024, en), '5.0 MB');
      expect(formatBytes(150 * 1024 * 1024, en), '150 MB');
      expect(formatBytes((2.5 * 1024 * 1024 * 1024).round(), en), '2.50 GB');
      expect(formatBytes(1536, ru), '1,5 КБ');
    });

    test('speed and eta', () {
      expect(formatSpeed(2.5 * 1024 * 1024, en), '2.5 MB/s');
      expect(formatSpeed(2.5 * 1024 * 1024, ru), '2,5 МБ/с');
      expect(formatEta(const Duration(milliseconds: 200), en), '1 s');
      expect(formatEta(const Duration(seconds: 42), en), '42 s');
      expect(formatEta(const Duration(seconds: 185), en), '3 min 05 s');
      expect(formatEta(const Duration(seconds: 4500), en), '1 h 15 min');
    });

    test('dates', () {
      final t = DateTime(2026, 3, 9, 7, 5);
      expect(formatModified(t, en), '2026-03-09 07:05');
      expect(formatModified(t, ru), '09.03.2026 07:05');
    });

    test('file kinds', () {
      expect(fileKindOf('a.JPG'), FileKind.image);
      expect(fileKindOf('movie.mkv'), FileKind.video);
      expect(fileKindOf('x.tar.gz'), FileKind.archive);
      expect(fileKindOf('.bashrc'), FileKind.other);
      expect(fileKindOf('noext'), FileKind.other);
      expect(fileKindOf('trailing.'), FileKind.other);
      expect(fileKindOf('docs', isDir: true), FileKind.folder);
    });
  });

  group('FileDropTarget', () {
    // The framework checks the override is back to null when the test body
    // ends, i.e. before any tearDown runs.
    Future<void> on(TargetPlatform p, Future<void> Function() body) async {
      debugDefaultTargetPlatformOverride = p;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    Future<void> channelCall(WidgetTester tester, String method, [Object? args]) async {
      const codec = StandardMethodCodec();
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'desktop_drop',
        codec.encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );
      await tester.pump();
    }

    testWidgets('is a plain wrapper on Android', (tester) async {
      await on(TargetPlatform.android, () async {
        await tester.pumpWidget(host(FileDropTarget(onFiles: (_) {}, child: const Text('content'))));
        expect(find.text('content'), findsOneWidget);
        expect(find.byType(DropTarget), findsNothing);
      });
    });

    testWidgets('shows the overlay while dragging and reports dropped paths on desktop', (tester) async {
      await on(TargetPlatform.macOS, () async {
        List<String>? dropped;
        await tester.pumpWidget(host(FileDropTarget(onFiles: (p) => dropped = p, child: const SizedBox.expand(child: Text('content')))));
        expect(find.byType(DropTarget), findsOneWidget);
        expect(find.text('Drop files to send'), findsNothing);

        await channelCall(tester, 'entered', [10.0, 10.0]);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Drop files to send'), findsOneWidget);
        expect(find.text('content'), findsOneWidget);

        await channelCall(tester, 'exited');
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Drop files to send'), findsNothing);

        await channelCall(tester, 'entered', [10.0, 10.0]);
        await channelCall(tester, 'performOperation', ['/tmp/a.txt', '/tmp/folder']);
        await tester.pump(const Duration(milliseconds: 300));
        expect(dropped, ['/tmp/a.txt', '/tmp/folder']);
        expect(find.text('Drop files to send'), findsNothing);
      });
    });

    testWidgets('the overlay speaks Russian for ru', (tester) async {
      await on(TargetPlatform.windows, () async {
        await tester.pumpWidget(host(
          FileDropTarget(onFiles: (_) {}, child: const SizedBox.expand()),
          locale: const Locale('ru'),
        ));
        await channelCall(tester, 'entered', [10.0, 10.0]);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Отпустите файлы, чтобы отправить'), findsOneWidget);
        await channelCall(tester, 'exited');
        await tester.pump(const Duration(milliseconds: 300));
      });
    });

    testWidgets('a disabled target ignores drags', (tester) async {
      await on(TargetPlatform.linux, () async {
        var calls = 0;
        await tester.pumpWidget(host(FileDropTarget(enabled: false, onFiles: (_) => calls++, child: const SizedBox.expand())));
        await channelCall(tester, 'entered', [10.0, 10.0]);
        await channelCall(tester, 'performOperation', ['/tmp/a']);
        expect(calls, 0);
        expect(find.text('Drop files to send'), findsNothing);
      });
    });
  });

  group('FileTransferPanel', () {
    testWidgets('viewer: empty state, then queue and remote browser', (tester) async {
      late Rig rig;
      late Directory remote;
      await tester.runAsync(() async {
        remote = await Directory.systemTemp.createTemp('thelxis_ui_remote_');
        await Directory('${remote.path}/Projects').create();
        await File('${remote.path}/notes.txt').writeAsString('hello');
        await File('${remote.path}/.hidden_file').writeAsString('x');
        rig = await Rig.create(hostRoots: () async => [FsRoot(name: 'Home', path: remote.path, kind: 'home')]);
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          await rig.dispose();
          await remote.delete(recursive: true);
        });
      });

      await tester.pumpWidget(host(FileTransferPanel(rig.viewer)));
      await settle(tester);

      // Empty state with a Send button.
      expect(find.text('No transfers yet'), findsOneWidget);
      expect(find.text('Send'), findsWidgets);
      expect(find.text('Remote files'), findsOneWidget);

      // Remote tab: places + listing, hidden files off by default.
      await tester.tap(find.text('Remote files'));
      await settle(tester);
      expect(find.text('Home'), findsWidgets);
      expect(find.text('Projects'), findsOneWidget);
      expect(find.text('notes.txt'), findsOneWidget);
      expect(find.text('.hidden_file'), findsNothing);

      await tester.tap(find.byTooltip('Show hidden files'));
      await tester.pumpAndSettle();
      expect(find.text('.hidden_file'), findsOneWidget);

      // Select a file and download it: the panel jumps to the queue.
      await tester.tap(find.text('notes.txt')); // touch layout: a tap on a file toggles it
      await tester.pumpAndSettle();
      expect(find.text('Download'), findsOneWidget);
      await tester.tap(find.text('Download'));
      await settle(tester, until: () => rig.viewer.transfers.isNotEmpty && rig.viewer.transfers.every((t) => t.isFinished));

      // The queue tile is on screen (the kept-alive remote list still holds a row too).
      expect(find.text('Received'), findsOneWidget);
      expect(find.text('Finished'.toUpperCase()), findsOneWidget);
      expect(rig.viewer.transfers.single.isCompleted, isTrue);
      expect(await tester.runAsync(() => File('${rig.viewerIncoming.path}/notes.txt').readAsString()), 'hello');
    });

    testWidgets('viewer: a tap opens a folder on touch devices, Up goes back', (tester) async {
      late Rig rig;
      late Directory remote;
      await tester.runAsync(() async {
        remote = await Directory.systemTemp.createTemp('thelxis_ui_remote_');
        await File('${remote.path}/Docs/inner.pdf').create(recursive: true);
        rig = await Rig.create(hostRoots: () async => [FsRoot(name: 'Home', path: remote.path, kind: 'home')]);
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          await rig.dispose();
          await remote.delete(recursive: true);
        });
      });
      await tester.pumpWidget(host(FileTransferPanel(rig.viewer)));
      await tester.tap(find.text('Remote files'));
      // Wait for the roots + listing round trip to land instead of a fixed
      // number of frames: under CI load the real I/O takes arbitrarily long.
      await settle(tester, until: () => find.text('Docs').evaluate().isNotEmpty);
      // Also let the tab slide and the list cross-fade finish (fake time), or
      // the row is still moving and the tap misses it.
      await tester.pumpAndSettle();

      await tester.tap(find.text('Docs').last);
      await settle(tester, until: () => find.text('inner.pdf').evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.text('inner.pdf'), findsOneWidget);

      await tester.tap(find.byTooltip('Up'));
      // The old listing stays on screen while the parent loads, so "gone" must
      // also mean the spinner finished and the parent listing is shown.
      await settle(tester, until: () =>
          find.text('inner.pdf').evaluate().isEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty &&
          find.text('Docs').evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.text('inner.pdf'), findsNothing);
      expect(find.text('Docs'), findsWidgets);
    });

    testWidgets('viewer: access denied by the host shows a clear message', (tester) async {
      late Rig rig;
      await tester.runAsync(() async {
        rig = await Rig.create();
        rig.hostAllowed = false;
      });
      addTearDown(() => tester.runAsync(rig.dispose));
      await tester.pumpWidget(host(FileTransferPanel(rig.viewer)));
      await tester.tap(find.text('Remote files'));
      await settle(tester);
      expect(find.text('Access to files is not allowed on the other device'), findsOneWidget);
    });

    testWidgets('host: only the queue, no remote browser', (tester) async {
      late Rig rig;
      await tester.runAsync(() async => rig = await Rig.create());
      addTearDown(() => tester.runAsync(rig.dispose));
      await tester.pumpWidget(host(FileTransferPanel(rig.host, onClose: () {})));
      await settle(tester);
      expect(find.text('Remote files'), findsNothing);
      expect(find.text('No transfers yet'), findsOneWidget);
      expect(find.byTooltip('Close'), findsOneWidget);
    });

    testWidgets('queue shows progress, finished and failed transfers; clear removes them', (tester) async {
      late Rig rig;
      await tester.runAsync(() async {
        rig = await Rig.create();
        final ok = await rig.makeFile('report.pdf', 5000);
        await rig.viewer.sendFiles([ok.path, '${rig.source.path}/missing.zip']);
        await rig.viewer.whenIdle();
      });
      addTearDown(() => tester.runAsync(rig.dispose));
      await tester.pumpWidget(host(FileTransferPanel(rig.viewer)));
      await settle(tester);
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('missing.zip'), findsOneWidget);
      expect(find.text('Sent'), findsOneWidget);
      expect(find.text('File not found'), findsOneWidget);
      expect(find.text('Clear finished'), findsOneWidget);

      await tester.tap(find.text('Clear finished'));
      await settle(tester);
      expect(find.text('report.pdf'), findsNothing);
      expect(find.text('No transfers yet'), findsOneWidget);
    });

    testWidgets('Russian locale', (tester) async {
      late Rig rig;
      await tester.runAsync(() async => rig = await Rig.create());
      addTearDown(() => tester.runAsync(rig.dispose));
      await tester.pumpWidget(host(FileTransferPanel(rig.viewer), locale: const Locale('ru')));
      await settle(tester);
      expect(find.text('Файлы'), findsOneWidget);
      expect(find.text('Передач пока нет'), findsOneWidget);
      expect(find.text('Файлы устройства'), findsOneWidget);
    });

    testWidgets('dark theme builds without errors', (tester) async {
      late Rig rig;
      await tester.runAsync(() async => rig = await Rig.create());
      addTearDown(() => tester.runAsync(rig.dispose));
      await tester.pumpWidget(host(FileTransferPanel(rig.viewer), mode: ThemeMode.dark));
      await settle(tester);
      expect(tester.takeException(), isNull);
    });
  });
}
