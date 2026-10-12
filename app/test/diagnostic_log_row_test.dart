import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/core/log.dart';
import 'package:thelxis/core/log_file.dart';
import 'package:thelxis/ui/settings/diagnostic_log_row.dart';
import 'package:thelxis/ui/theme.dart';

void main() {
  late Directory tmp;
  late LogFile log;
  String? clipboard;
  final revealed = <String>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('thelxis_log_ui_');
    log = LogFile(Directory('${tmp.path}/logs'));
    clipboard = null;
    revealed.clear();
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> pumpRow(WidgetTester tester, {bool showFolder = true}) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(
          child: DiagnosticLogRow(
            log: log,
            showFolder: showFolder,
            reveal: (_, path) async => revealed.add(path),
          ),
        ),
      ),
    ));
  }

  /// Taps [key] while real IO is allowed to complete, then settles the UI.
  Future<void> tapAndWait(WidgetTester tester, String key) async {
    await tester.runAsync(() async {
      await tester.tap(find.byKey(ValueKey(key)));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
  }

  Future<void> seed(WidgetTester tester, int lines) => tester.runAsync(() async {
        for (var i = 0; i < lines; i++) {
          log.add(LogLevel.info, '[info] t: line $i');
        }
        await log.flush();
      });

  testWidgets('shows the three actions with English labels', (tester) async {
    await pumpRow(tester);
    expect(find.text('Diagnostic log'), findsOneWidget);
    expect(find.text('Show in folder'), findsOneWidget);
    expect(find.text('Copy log'), findsOneWidget);
    expect(find.text('Clear'), findsOneWidget);
  });

  testWidgets('hides "Show in folder" where there is no file manager', (tester) async {
    await pumpRow(tester, showFolder: false);
    expect(find.byKey(const ValueKey('log-folder')), findsNothing);
    expect(find.byKey(const ValueKey('log-copy')), findsOneWidget);
  });

  testWidgets('Show in folder reveals the log file location', (tester) async {
    await pumpRow(tester);
    await tapAndWait(tester, 'log-folder');
    expect(revealed, [log.current.path]);
  });

  testWidgets('Copy log copies the last 200 lines', (tester) async {
    await seed(tester, 250);
    await pumpRow(tester);
    await tapAndWait(tester, 'log-copy');
    final lines = clipboard!.split('\n');
    expect(lines, hasLength(DiagnosticLogRow.copyLines));
    expect(lines.first, endsWith('line 50'));
    expect(lines.last, endsWith('line 249'));
    expect(find.text('Diagnostic log copied'), findsOneWidget);
  });

  testWidgets('Copy log on an empty log says so and copies nothing', (tester) async {
    await pumpRow(tester);
    await tapAndWait(tester, 'log-copy');
    expect(clipboard, isNull);
    expect(find.text('The log is empty'), findsOneWidget);
  });

  testWidgets('Clear deletes the log', (tester) async {
    await seed(tester, 5);
    expect(log.current.existsSync(), isTrue);
    await pumpRow(tester);
    await tapAndWait(tester, 'log-clear');
    expect(log.current.existsSync(), isFalse);
    expect(find.text('Diagnostic log cleared'), findsOneWidget);
  });
}
