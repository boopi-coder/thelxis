import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/core/log.dart';
import 'package:thelxis/desktop/mac_login_item.dart';

const _exe = '/Applications/Thelxis.app/Contents/MacOS/Thelxis';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Logger.sink = (_, _) {};

  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('thelxis_home_');
  });
  tearDown(() => home.delete(recursive: true));

  MacLoginItem item({String exe = _exe}) => MacLoginItem(homeDir: home.path, executable: exe);

  test('the plist launches the app minimized, at login, in the GUI session', () {
    final xml = item().buildPlist();
    expect(xml, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
    expect(xml, contains('<key>Label</key>\n  <string>io.thelxis.app</string>'));
    expect(
      xml,
      contains('<key>ProgramArguments</key>\n  <array>\n    <string>$_exe</string>\n    <string>--minimized</string>\n  </array>'),
    );
    expect(xml, contains('<key>RunAtLoad</key>\n  <true/>'));
    expect(xml, contains('<key>ProcessType</key>\n  <string>Interactive</string>'));
    expect(xml, contains('<key>LimitLoadToSessionType</key>\n  <string>Aqua</string>'));
  });

  test('paths with XML metacharacters are escaped and still recognised as current', () async {
    const odd = '/Applications/R&D <Tools>/Thelxis.app/Contents/MacOS/Thelxis';
    final it = item(exe: odd);
    final xml = it.buildPlist();
    expect(xml, contains('R&amp;D &lt;Tools&gt;'));
    expect(xml, isNot(contains('R&D <Tools>')));
    await it.enable();
    expect(await it.isEnabled(), isTrue);
  });

  test('enable writes ~/Library/LaunchAgents/io.thelxis.app.plist, disable removes it', () async {
    final it = item();
    expect(it.plistFile.path, '${home.path}/Library/LaunchAgents/io.thelxis.app.plist');
    expect(await it.isEnabled(), isFalse);

    await it.enable();
    expect(it.plistFile.existsSync(), isTrue, reason: 'the LaunchAgents folder is created when missing');
    expect(it.plistFile.readAsStringSync(), it.buildPlist());
    expect(await it.isEnabled(), isTrue);
    expect(File('${it.plistFile.path}.tmp').existsSync(), isFalse, reason: 'no temp file left behind');

    await it.disable();
    expect(it.plistFile.existsSync(), isFalse);
    expect(await it.isEnabled(), isFalse);
    await it.disable(); // idempotent
  });

  test('a plist that points at another location of the app is not "enabled" and gets rewritten', () async {
    await item(exe: '/Users/me/Downloads/Thelxis.app/Contents/MacOS/Thelxis').enable();
    final current = item();
    expect(await current.isEnabled(), isFalse, reason: 'the app moved');

    await current.sync(true);
    expect(await current.isEnabled(), isTrue);
    expect(current.plistFile.readAsStringSync(), current.buildPlist());
  });

  test('syncing "on" twice leaves an up-to-date file alone; syncing "off" removes a stale one', () async {
    final it = item();
    await it.sync(true);
    final stamp = it.plistFile.statSync().modified;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await it.sync(true);
    expect(it.plistFile.statSync().modified, stamp);

    await item(exe: '/old/Thelxis').enable();
    await it.sync(false);
    expect(it.plistFile.existsSync(), isFalse);
  });

  test('an app translocated by Gatekeeper is not registered (its path vanishes on quit)', () async {
    final it = item(exe: '/private/var/folders/xx/T/AppTranslocation/ABC/d/Thelxis.app/Contents/MacOS/Thelxis');
    await it.enable();
    expect(it.plistFile.existsSync(), isFalse);
  });

  test('a missing HOME never throws', () async {
    final it = MacLoginItem(homeDir: '', executable: _exe);
    await it.enable();
    await it.disable();
    expect(await it.isEnabled(), isFalse);
  });

  test('launchd accepts the file (plutil -lint)', () async {
    final it = item();
    await it.enable();
    final r = await Process.run('plutil', ['-lint', it.plistFile.path]);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
  }, skip: Platform.isMacOS ? false : 'plutil only exists on macOS');
}
