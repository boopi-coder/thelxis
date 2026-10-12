import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/core/log.dart';
import 'package:thelxis/core/log_file.dart';
import 'package:thelxis/core/system_info.dart';

void main() {
  late Directory tmp;
  final fixed = DateTime.utc(2026, 10, 12, 9, 30);

  setUp(() => tmp = Directory.systemTemp.createTempSync('thelxis_log_'));
  tearDown(() {
    LogFile.install(null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  LogFile make({int maxBytes = LogFile.defaultMaxBytes, Duration interval = const Duration(milliseconds: 20)}) =>
      LogFile(Directory('${tmp.path}/logs'), maxBytes: maxBytes, flushInterval: interval, clock: () => fixed);

  test('is off under flutter test unless a test installs one', () async {
    expect(await LogFile.start(), isNull);
    expect(LogFile.instance, isNull);
    expect(Logger.fileSink, isNull);
  });

  test('buffers lines and flushes them asynchronously after the interval', () async {
    final log = make(interval: const Duration(milliseconds: 50));
    log.add(LogLevel.info, '[info] net: listening on port 47100');
    log.add(LogLevel.warn, '[warn] net: two\nlines');
    expect(log.current.existsSync(), isFalse, reason: 'nothing is written synchronously');

    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(log.current.readAsStringSync(),
        '2026-10-12T09:30:00.000Z [info] net: listening on port 47100\n'
        '2026-10-12T09:30:00.000Z [warn] net: two\n    lines\n');
  });

  test('errors are written without waiting for the interval', () async {
    final log = make(interval: const Duration(hours: 1));
    log.add(LogLevel.error, '[error] main: boom');
    await log.flush();
    expect(log.current.readAsStringSync(), contains('boom'));
  });

  test('rotates past maxBytes and keeps at most two files', () async {
    final log = make(maxBytes: 300);
    // Two ~71-byte lines per flush: every third flush crosses 300 bytes.
    for (var round = 0; round < 7; round++) {
      for (var i = 0; i < 2; i++) {
        log.add(LogLevel.info, '[info] t: round $round line $i ${'x' * 20}');
      }
      await log.flush();
    }
    final names = Directory('${tmp.path}/logs').listSync().map((e) => e.uri.pathSegments.last).toSet();
    expect(names, {LogFile.fileName, LogFile.previousFileName});
    expect(log.previous.readAsStringSync(), allOf(contains('round 3'), contains('round 5')));
    expect(log.previous.readAsStringSync(), isNot(contains('round 2')), reason: 'older history is dropped');
    expect(log.current.readAsStringSync(), contains('round 6'));
    expect(log.previous.lengthSync(), greaterThan(300));
  });

  test('tail spans the rotated file and returns the last lines', () async {
    final log = make(maxBytes: 200);
    // Rotation after every fourth line: 16-19 rotated, 20 current.
    for (var i = 0; i < 21; i++) {
      log.add(LogLevel.info, 'line $i ${'y' * 30}');
      await log.flush();
    }
    final tail = await log.tail(lines: 3);
    final lines = tail.split('\n');
    expect(lines, hasLength(3));
    expect(lines.last, contains('line 20'));
    expect(lines.first, contains('line 18'));
  });

  test('clear removes both files and the buffer', () async {
    final log = make(maxBytes: 100);
    for (var i = 0; i < 10; i++) {
      log.add(LogLevel.info, 'line $i ${'z' * 30}');
      await log.flush();
    }
    log.add(LogLevel.info, 'pending');
    await log.clear();
    expect(log.current.existsSync(), isFalse);
    expect(log.previous.existsSync(), isFalse);
    expect(await log.tail(), isEmpty);
  });

  test('never throws when the directory cannot be written', () async {
    // A regular file where the logs directory should be.
    final blocker = File('${tmp.path}/logs')..writeAsStringSync('not a dir');
    final log = make();
    expect(() => log.add(LogLevel.error, 'x'), returnsNormally);
    log.add(LogLevel.info, 'y');
    await log.flush();
    log.flushSync();
    expect(await log.tail(), isEmpty);
    await log.clear();
    expect(blocker.readAsStringSync(), 'not a dir');
  });

  test('redacts values that look like secrets', () {
    String r(String s) => LogFile.redact(s);
    expect(r('a=ice-pwd:asd88fd9a8sdf a=ice-ufrag:abcd'), 'a=ice-pwd:*** a=ice-ufrag:abcd');
    expect(r('password=hunter2 next'), 'password=*** next');
    expect(r('permanentPassword: hunter2'), 'permanentPassword: ***');
    expect(r('{"proof":"q1w2e3","id":"5"}'), '{"proof":"***","id":"5"}');
    expect(r('turn credential=abc;user=bob'), 'turn credential=***;user=bob');
    expect(r('Authorization: Bearer abc.def'), 'Authorization: ***');
    expect(r('sent Bearer abc.def'), 'sent Bearer ***');
    expect(r('token=abc&x=1'), 'token=***&x=1');
    expect(r('otp: 123456'), 'otp: ***');
    expect(r('secret = s3'), 'secret = ***');
    // Ordinary diagnostics stay intact.
    expect(r('[info] net: listening on port 47100'), '[info] net: listening on port 47100');
    expect(r('screenCapture=granted inputControl=denied'), 'screenCapture=granted inputControl=denied');
  });

  test('Logger routes into the installed file and still feeds the test sink', () async {
    final log = make();
    LogFile.install(log);
    final seen = <String>[];
    final previousSink = Logger.sink;
    Logger.sink = (_, line) => seen.add(line);
    addTearDown(() => Logger.sink = previousSink);

    const Logger('t').w('auth failed, token=abc123');
    await log.flush();
    expect(seen.single, contains('token=abc123'));
    final text = log.current.readAsStringSync();
    expect(text, contains('[warn] t: auth failed, token=***'));
    expect(text, isNot(contains('abc123')));
  });

  test('environment header names version, OS, arch and permissions', () {
    const info = SystemInfo(
      os: 'macos',
      osVersion: '15.6',
      arch: 'arm64',
      hostname: 'h',
      appVersion: '0.3.1',
      defaultDeviceName: 'd',
    );
    expect(environmentHeader(info, {'screenCapture': 'granted', 'inputControl': 'denied'}),
        'Thelxis 0.3.1 on macos 15.6 (arm64); permissions: screenCapture=granted inputControl=denied');
  });
}
