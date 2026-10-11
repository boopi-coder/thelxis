import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/update/installers/android_installer.dart';
import 'package:thelxis/update/installers/installer.dart';
import 'package:thelxis/update/manifest.dart';
import 'package:thelxis/update/update_exception.dart';

import 'support/update_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.thelxis/updater');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final asset = UpdateAsset(
    name: 'a.apk',
    url: Uri.parse('https://github.com/boopi-coder/thelxis/releases/download/v0.2.0/a.apk'),
    size: 3,
    sha256: sha256Hex([1, 2, 3]),
  );
  final apk = File('/data/user/0/io.thelxis/files/updates/a.apk');
  late List<MethodCall> calls;

  void handle(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(() => calls = []);
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('uses the documented channel name', () {
    expect(AndroidInstaller.channelName, 'io.thelxis/updater');
    expect(AndroidInstaller().requiresUserConfirmation, isTrue);
  });

  test('without the install permission it opens the settings and asks for a manual step', () async {
    handle((call) async => call.method == 'canRequestInstalls' ? false : null);
    final result = await AndroidInstaller().install(apk, asset);

    expect(result.outcome, InstallOutcome.manualRequired);
    expect(result.reason, ManualInstallReason.installPermission);
    expect(calls.map((c) => c.method), ['canRequestInstalls', 'openInstallSettings']);
  });

  test('with the permission it launches the system installer for the downloaded path', () async {
    handle((call) async => call.method == 'canRequestInstalls' || call.method == 'installApk');
    final result = await AndroidInstaller().install(apk, asset);

    expect(result.outcome, InstallOutcome.handedOff);
    expect(calls.map((c) => c.method), ['canRequestInstalls', 'installApk']);
    expect(calls.last.arguments, {'path': apk.path});
  });

  test('native failures become install errors', () async {
    handle((call) async => call.method == 'canRequestInstalls');
    var e = await _failureOf(AndroidInstaller().install(apk, asset));
    expect(e.kind, UpdateErrorKind.install, reason: 'installApk returned false');

    handle((call) async => throw PlatformException(code: 'no_activity'));
    e = await _failureOf(AndroidInstaller().install(apk, asset));
    expect(e.kind, UpdateErrorKind.install);

    messenger.setMockMethodCallHandler(channel, null);
    e = await _failureOf(AndroidInstaller().install(apk, asset));
    expect(e.detail, contains('not implemented'));
  });
}

Future<UpdateException> _failureOf(Future<Object?> future) async {
  try {
    await future;
  } on UpdateException catch (e) {
    return e;
  }
  fail('expected an UpdateException');
}
