import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/update/installers/installer.dart';
import 'package:thelxis/update/installers/installer_factory.dart';
import 'package:thelxis/update/installers/linux_installer.dart';
import 'package:thelxis/update/installers/macos_installer.dart';
import 'package:thelxis/update/installers/windows_installer.dart';
import 'package:thelxis/update/manifest.dart';
import 'package:thelxis/update/update_exception.dart';
import 'package:thelxis/update/update_target.dart';

import 'support/update_fakes.dart';

final _asset = UpdateAsset(
  name: 'Thelxis-0.2.0-test',
  url: Uri.parse('https://github.com/sibawal/thelxis/releases/download/v0.2.0/x'),
  size: 3,
  sha256: sha256Hex([1, 2, 3]),
);

Future<UpdateException> failureOf(Future<Object?> future) async {
  try {
    await future;
  } on UpdateException catch (e) {
    return e;
  }
  fail('expected an UpdateException');
}

/// The value following [flag] in [args].
String after(List<String> args, String flag) => args[args.indexOf(flag) + 1];

bool get _isRoot => !Platform.isWindows && Process.runSync('id', ['-u']).stdout.toString().trim() == '0';

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('thelxis-installer-test-'));
  tearDown(() async {
    // Undo the read-only directory of the "not writable" tests.
    if (!Platform.isWindows) await Process.run('chmod', ['-R', 'u+rwX', root.path]);
    await root.delete(recursive: true);
  });

  File downloaded(String name) => File('${root.path}/$name')..writeAsBytesSync([1, 2, 3]);

  group('Windows', () {
    test('starts the Inno Setup installer elevated with the documented switches', () async {
      String? file;
      String? args;
      final installer = WindowsInstaller(launch: (f, a) async {
        file = f;
        args = a;
        return 42;
      });
      final result = await installer.install(downloaded('setup.exe'), _asset);

      expect(result.outcome, InstallOutcome.restartRequired);
      expect(file, endsWith('setup.exe'));
      expect(args, '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /RELAUNCH');
      expect(installer.requiresUserConfirmation, isTrue);
    });

    test('a declined UAC prompt is reported and nothing is restarted', () async {
      final denied = await failureOf(
        WindowsInstaller(launch: (_, _) async => 5).install(downloaded('setup.exe'), _asset),
      );
      expect(denied.kind, UpdateErrorKind.elevationDenied);
      final other = await failureOf(
        WindowsInstaller(launch: (_, _) async => 2).install(downloaded('setup.exe'), _asset),
      );
      expect(other.kind, UpdateErrorKind.install);
    });
  });

  group('Linux .deb', () {
    test('installs through pkexec with a root-side hash check, then relaunches', () async {
      final proc = FakeProcessLauncher();
      final result = await LinuxDebInstaller(process: proc, ownPid: 4242).install(downloaded('t.deb'), _asset);

      expect(result.outcome, InstallOutcome.restartRequired);
      expect(proc.runs.first, ['pkexec', '--version']);
      final install = proc.runs[1];
      expect(install.sublist(0, 3), ['pkexec', '/bin/sh', '-c']);
      expect(install[3], LinuxDebInstaller.rootScript);
      expect(install.sublist(4), ['sh', '${root.path}/t.deb', _asset.sha256]);
      expect(LinuxDebInstaller.rootScript, contains('sha256sum -c'));
      expect(LinuxDebInstaller.rootScript, contains('dpkg -i'));

      expect(proc.detached.single.sublist(0, 3), ['/bin/sh', '-c', LinuxDebInstaller.relaunchScript]);
      expect(proc.detached.single.sublist(3), ['sh', '4242', '/usr/bin/thelxis', '--updated']);
    });

    test('without pkexec the folder is opened and the user installs by hand', () async {
      final proc = FakeProcessLauncher()
        ..onRun = (exe, args) {
          if (exe == 'pkexec') throw const ProcessException('pkexec', ['--version'], 'not found');
          return stubResult(0);
        };
      final result = await LinuxDebInstaller(process: proc).install(downloaded('t.deb'), _asset);

      expect(result.outcome, InstallOutcome.manualRequired);
      expect(result.reason, ManualInstallReason.noPolkit);
      expect(result.location, endsWith('t.deb'));
      expect(proc.runs.last, ['xdg-open', root.path]);
      expect(proc.detached, isEmpty);
    });

    test('declined prompt and dpkg failures are distinguished', () async {
      for (final code in [126, 127]) {
        final proc = FakeProcessLauncher()
          ..onRun = (exe, args) => args.contains('--version') ? stubResult(0) : stubResult(code);
        final e = await failureOf(LinuxDebInstaller(process: proc).install(downloaded('t.deb'), _asset));
        expect(e.kind, UpdateErrorKind.elevationDenied, reason: 'exit $code');
        expect(proc.detached, isEmpty);
      }
      final proc = FakeProcessLauncher()
        ..onRun = (exe, args) => args.contains('--version') ? stubResult(0) : stubResult(1, err: 'dpkg: dependency problems');
      final e = await failureOf(LinuxDebInstaller(process: proc).install(downloaded('t.deb'), _asset));
      expect(e.kind, UpdateErrorKind.install);
      expect(e.detail, contains('dependency problems'));
      expect(proc.detached, isEmpty, reason: 'the app must not restart after a failed install');
    });
  });

  group('Linux tar.gz', () {
    late Directory bundle;
    setUp(() async {
      bundle = await Directory('${root.path}/apps/Thelxis').create(recursive: true);
      File('${bundle.path}/thelxis').writeAsStringSync('old');
    });

    FakeProcessLauncher extracting({bool withExecutable = true}) => FakeProcessLauncher()
      ..onRun = (exe, args) {
        if (exe == 'tar') {
          final top = Directory('${after(args, '-C')}/Thelxis-0.2.0-linux-x64')..createSync(recursive: true);
          if (withExecutable) File('${top.path}/thelxis').writeAsStringSync('new');
        }
        return stubResult(0);
      };

    test('unpacks next to the bundle and hands the swap to a detached script', () async {
      final proc = extracting();
      final installer = LinuxTarInstaller(
        process: proc,
        resolvedExecutable: '${bundle.path}/thelxis',
        ownPid: 777,
        tempRoot: root,
      );
      final result = await installer.install(downloaded('t.tar.gz'), _asset);

      expect(result.outcome, InstallOutcome.restartRequired);
      final tar = proc.runs.single;
      expect(tar.sublist(0, 2), ['tar', '-xzf']);
      expect(tar[2], '${root.path}/t.tar.gz');
      final staging = after(tar, '-C');
      expect(Directory(staging).parent.path, '${root.path}/apps', reason: 'same filesystem as the bundle');

      final launch = proc.detached.single;
      expect(launch[0], '/bin/sh');
      expect(File(launch[1]).readAsStringSync(), LinuxTarInstaller.swapScript);
      expect(launch.sublist(2), ['777', bundle.path, '$staging/Thelxis-0.2.0-linux-x64', staging, 'thelxis']);
    });

    test('an archive without the executable is rejected and cleaned up', () async {
      final proc = extracting(withExecutable: false);
      final installer = LinuxTarInstaller(
        process: proc,
        resolvedExecutable: '${bundle.path}/thelxis',
        tempRoot: root,
      );
      final e = await failureOf(installer.install(downloaded('t.tar.gz'), _asset));
      expect(e.kind, UpdateErrorKind.install);
      expect(proc.detached, isEmpty);
      expect(Directory('${root.path}/apps').listSync().whereType<Directory>().map((d) => d.path), [bundle.path]);
    });

    test('a read-only install location falls back to a manual install', () async {
      if (Platform.isWindows || _isRoot) return;
      await Process.run('chmod', ['555', '${root.path}/apps']);
      final proc = FakeProcessLauncher();
      final result = await LinuxTarInstaller(
        process: proc,
        resolvedExecutable: '${bundle.path}/thelxis',
        tempRoot: root,
      ).install(downloaded('t.tar.gz'), _asset);

      expect(result.reason, ManualInstallReason.notWritable);
      expect(proc.runs.single, ['xdg-open', root.path]);
      expect(proc.detached, isEmpty);
    });
  });

  group('macOS', () {
    late Directory apps;
    late Directory tmp;
    setUp(() async {
      apps = await Directory('${root.path}/Applications').create();
      tmp = await Directory('${root.path}/tmp').create();
      Directory('${apps.path}/Thelxis.app/Contents/MacOS').createSync(recursive: true);
      File('${apps.path}/Thelxis.app/Contents/MacOS/Thelxis').writeAsStringSync('old');
    });

    MacosInstaller installerWith(FakeProcessLauncher proc) => MacosInstaller(
          process: proc,
          resolvedExecutable: '${apps.path}/Thelxis.app/Contents/MacOS/Thelxis',
          ownPid: 555,
          tempRoot: tmp,
        );

    FakeProcessLauncher mounting({int ditto = 0}) => FakeProcessLauncher()
      ..onRun = (exe, args) {
        if (exe == 'hdiutil' && args.first == 'attach') {
          Directory('${after(args, '-mountpoint')}/Thelxis.app/Contents').createSync(recursive: true);
        }
        if (exe == 'ditto') {
          if (ditto != 0) return stubResult(ditto, err: 'ditto: out of space');
          Directory(args[1]).createSync(recursive: true);
        }
        return stubResult(0);
      };

    test('mounts, stages next to the bundle, verifies, unmounts and starts the swap script', () async {
      final proc = mounting();
      final dmg = downloaded('Thelxis.dmg');
      final result = await installerWith(proc).install(dmg, _asset);

      expect(result.outcome, InstallOutcome.restartRequired);
      final attach = proc.runs[0];
      expect(attach.sublist(0, 2), ['hdiutil', 'attach']);
      expect(attach, containsAll(['-nobrowse', '-readonly']));
      final mount = after(attach, '-mountpoint');
      expect(attach.last, dmg.path);

      final ditto = proc.runs[1];
      expect(ditto[0], 'ditto');
      expect(ditto[1], '$mount/Thelxis.app');
      final staged = ditto[2];
      expect(staged, endsWith('/Thelxis.app'));
      final staging = Directory(staged).parent;
      expect(staging.parent.path, apps.path, reason: 'same volume as the bundle: mv is an atomic rename');
      expect(staging.path.split('/').last, startsWith('.thelxis-update-'));

      expect(proc.runs[2], ['codesign', '--verify', '--deep', '--strict', staged]);
      expect(proc.runs[3], ['hdiutil', 'detach', mount]);
      expect(Directory(mount).existsSync(), isFalse, reason: 'the mount point is removed');

      final launch = proc.detached.single;
      expect(launch[0], '/bin/sh');
      expect(File(launch[1]).readAsStringSync(), MacosInstaller.swapScript);
      expect(launch.sublist(2), ['555', '${apps.path}/Thelxis.app', staged, staging.path]);
      expect(staging.existsSync(), isTrue, reason: 'the script needs the staged bundle');
    });

    test('a failed copy is reported, unmounted and leaves nothing behind', () async {
      final proc = mounting(ditto: 1);
      final e = await failureOf(installerWith(proc).install(downloaded('Thelxis.dmg'), _asset));

      expect(e.kind, UpdateErrorKind.install);
      expect(e.detail, contains('out of space'));
      expect(proc.runs.any((c) => c[0] == 'hdiutil' && c[1] == 'detach'), isTrue);
      expect(proc.detached, isEmpty);
      expect(apps.listSync().map((e) => e.path), ['${apps.path}/Thelxis.app']);
    });

    test('a bundle whose folder is read-only is opened in Finder instead', () async {
      if (_isRoot) return;
      await Process.run('chmod', ['555', apps.path]);
      final proc = mounting();
      final dmg = downloaded('Thelxis.dmg');
      final result = await installerWith(proc).install(dmg, _asset);

      expect(result.reason, ManualInstallReason.notWritable);
      expect(result.location, dmg.path);
      expect(proc.runs.single, ['open', dmg.path]);
      expect(proc.detached, isEmpty);
    });

    test('refuses to run when the app is not inside a .app bundle', () async {
      final installer = MacosInstaller(
        process: FakeProcessLauncher(),
        resolvedExecutable: '${root.path}/bin/thelxis',
        tempRoot: tmp,
      );
      expect((await failureOf(installer.install(downloaded('x.dmg'), _asset))).kind, UpdateErrorKind.install);
    });
  });

  group('swap scripts (really executed against stub tools)', () {
    late Directory stubs;
    late File log;

    setUp(() async {
      stubs = await Directory('${root.path}/stubs').create();
      log = File('${root.path}/calls.log')..writeAsStringSync('');
      for (final tool in ['open', 'xattr']) {
        final f = File('${stubs.path}/$tool')..writeAsStringSync('#!/bin/sh\necho "$tool \$@" >> "${log.path}"\n');
        await Process.run('chmod', ['755', f.path]);
      }
    });

    /// Runs [script] after a short-lived process "exits" (the app being replaced).
    Future<ProcessResult> runScript(String script, List<String> args) async {
      final scriptFile = File('${root.path}/swap.sh')..writeAsStringSync(script);
      final app = await Process.start('sleep', ['0.3']);
      final result = await Process.run(
        '/bin/sh',
        [scriptFile.path, '${app.pid}', ...args],
        environment: {'PATH': '${stubs.path}:/usr/bin:/bin'},
        includeParentEnvironment: false,
      );
      expect(scriptFile.existsSync(), isFalse, reason: 'the script deletes itself');
      return result;
    }

    test('macOS: waits for the app, swaps, strips quarantine, relaunches with --updated', () async {
      if (Platform.isWindows) return;
      final bundle = Directory('${root.path}/Apps/Thelxis.app')..createSync(recursive: true);
      File('${bundle.path}/version').writeAsStringSync('old');
      final stage = Directory('${root.path}/Apps/.stage')..createSync();
      Directory('${stage.path}/Thelxis.app').createSync();
      File('${stage.path}/Thelxis.app/version').writeAsStringSync('new');

      final started = DateTime.now();
      final r = await runScript(MacosInstaller.swapScript, [bundle.path, '${stage.path}/Thelxis.app', stage.path]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(DateTime.now().difference(started), greaterThan(const Duration(milliseconds: 250)));

      expect(File('${bundle.path}/version').readAsStringSync(), 'new');
      expect(Directory('${bundle.path}.bak').existsSync(), isFalse);
      expect(stage.existsSync(), isFalse);
      expect(log.readAsLinesSync(), [
        'xattr -dr com.apple.quarantine ${bundle.path}',
        'open -n ${bundle.path} --args --updated',
      ]);
    });

    test('macOS: a failed swap rolls back and relaunches the old app without --updated', () async {
      if (Platform.isWindows) return;
      final bundle = Directory('${root.path}/Apps/Thelxis.app')..createSync(recursive: true);
      File('${bundle.path}/version').writeAsStringSync('old');
      final stage = Directory('${root.path}/Apps/.stage')..createSync();

      await runScript(MacosInstaller.swapScript, [bundle.path, '${stage.path}/missing.app', stage.path]);
      expect(File('${bundle.path}/version').readAsStringSync(), 'old');
      expect(Directory('${bundle.path}.bak').existsSync(), isFalse);
      expect(log.readAsLinesSync().last, 'open -n ${bundle.path}');
    });

    test('Linux: swaps the bundle directory and execs the new binary with --updated', () async {
      if (Platform.isWindows) return;
      final bundle = Directory('${root.path}/apps/Thelxis')..createSync(recursive: true);
      File('${bundle.path}/thelxis').writeAsStringSync('old');
      final stage = Directory('${root.path}/apps/.stage')..createSync();
      final staged = Directory('${stage.path}/Thelxis-0.2.0-linux-x64')..createSync();
      final exe = File('${staged.path}/thelxis')..writeAsStringSync('#!/bin/sh\necho "new \$@" >> "${log.path}"\n');
      await Process.run('chmod', ['755', exe.path]);

      final r = await runScript(LinuxTarInstaller.swapScript, [bundle.path, staged.path, stage.path, 'thelxis']);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(log.readAsLinesSync(), ['new --updated']);
      expect(Directory('${bundle.path}.bak').existsSync(), isFalse);
      expect(stage.existsSync(), isFalse);
    });

    test('.deb relaunch helper waits for the PID and then execs the command', () async {
      if (Platform.isWindows) return;
      final app = await Process.start('sleep', ['0.3']);
      final started = DateTime.now();
      final r = await Process.run('/bin/sh', [
        '-c',
        LinuxDebInstaller.relaunchScript,
        'sh',
        '${app.pid}',
        '/bin/sh',
        '-c',
        'echo launched \$0 >> "${log.path}"',
        '--updated',
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(DateTime.now().difference(started), greaterThan(const Duration(milliseconds: 250)));
      expect(log.readAsLinesSync(), ['launched --updated']);
    });

    test('all shell snippets are syntactically valid', () async {
      if (Platform.isWindows) return;
      for (final script in [
        MacosInstaller.swapScript,
        LinuxTarInstaller.swapScript,
        LinuxDebInstaller.rootScript,
        LinuxDebInstaller.relaunchScript,
      ]) {
        final r = await Process.run('/bin/sh', ['-n', '-c', script]);
        expect(r.exitCode, 0, reason: '${r.stderr}\n$script');
      }
    });
  });

  test('the factory picks the installer for each platform', () {
    expect(createInstaller(const UpdateTarget(os: UpdateOs.windows)), isA<WindowsInstaller>());
    expect(createInstaller(const UpdateTarget(os: UpdateOs.macos)), isA<MacosInstaller>());
    expect(createInstaller(const UpdateTarget(os: UpdateOs.linux, linuxDeb: true)), isA<LinuxDebInstaller>());
    expect(createInstaller(const UpdateTarget(os: UpdateOs.linux)), isA<LinuxTarInstaller>());
    expect(createInstaller(const UpdateTarget(os: UpdateOs.unsupported)).requiresUserConfirmation, isFalse);
  });
}
