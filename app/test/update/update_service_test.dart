import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/core/log.dart';
import 'package:thelxis/update/installers/installer.dart';
import 'package:thelxis/update/update_exception.dart';
import 'package:thelxis/update/update_service.dart';

import 'support/update_fakes.dart';
import 'support/update_rig.dart';

const _noAutoInstall = {'update.autoInstall': false};

void main() {
  setUpAll(() => Logger.sink = (level, line) {});

  late UpdateRig rig;
  tearDown(() => rig.dispose());

  group('checking', () {
    test('a newer version becomes available and is not downloaded without autoInstall', () async {
      rig = await UpdateRig.create(prefsValues: _noAutoInstall);
      await rig.service.start();
      await rig.service.checkNow();

      expect(rig.service.state, UpdateState.available);
      expect(rig.service.availableVersion, '0.2.0');
      expect(rig.service.notesUrl.toString(), contains('v0.2.0'));
      expect(rig.service.asset!.name, contains('windows-x64'));
      expect(rig.service.lastCheck, isNotNull);
      expect(rig.prefs.getInt('update.lastCheck'), isNotNull);
      expect(rig.downloader.downloads, 0);
    });

    test('same, older and pre-release versions mean up to date', () async {
      for (final version in ['0.1.0', '0.0.9', '0.3.0-rc.1']) {
        rig = await UpdateRig.create(version: version);
        await rig.service.start();
        await rig.service.checkNow();
        expect(rig.service.state, UpdateState.upToDate, reason: version);
        expect(rig.service.offer, isNull, reason: version);
        await rig.dispose();
      }
      rig = await UpdateRig.create(); // so tearDown has something to dispose
    });

    test('0.1.10 is newer than 0.1.9', () async {
      rig = await UpdateRig.create(current: '0.1.9', version: '0.1.10', prefsValues: _noAutoInstall);
      await rig.service.start();
      await rig.service.checkNow();
      expect(rig.service.state, UpdateState.available);
    });

    test('a bad signature is an error and nothing is offered', () async {
      rig = await UpdateRig.create(wrongKey: true);
      await rig.service.start();
      await rig.service.checkNow();

      expect(rig.service.state, UpdateState.error);
      expect(rig.service.errorPhase, UpdatePhase.check);
      expect(rig.service.error!.kind, UpdateErrorKind.signatureInvalid);
      expect(rig.service.offer, isNull);
      expect(rig.downloader.downloads, 0);
      expect(rig.installer.installed, isEmpty);
    });

    test('a release without a build for this platform is an error', () async {
      rig = await UpdateRig.create();
      rig.manifest = manifestBytes(assets: {'macos-universal': assetJson('a.dmg', [1])});
      await rig.service.start();
      await rig.service.checkNow();
      expect(rig.service.state, UpdateState.error);
      expect(rig.service.error!.kind, UpdateErrorKind.noAsset);
    });

    test('a failed re-check keeps an offer the user can still act on', () async {
      rig = await UpdateRig.create(prefsValues: _noAutoInstall);
      await rig.service.start();
      await rig.service.checkNow();
      rig.failNetwork = true;
      await rig.service.checkNow();

      expect(rig.service.state, UpdateState.available);
      expect(rig.service.error!.kind, UpdateErrorKind.network);
      expect(rig.service.offer, isNotNull);
    });
  });

  group('schedule and settings', () {
    test('first check after the delay, then repeatedly', () async {
      rig = await UpdateRig.create(
        firstCheckDelay: const Duration(milliseconds: 20),
        checkInterval: const Duration(milliseconds: 40),
        prefsValues: _noAutoInstall,
      );
      await rig.service.start();
      expect(rig.manifestFetches, 0);
      await waitUntil(() => rig.manifestFetches >= 3);
      expect(rig.service.state, UpdateState.available);
    });

    test('automatic checks off: nothing is fetched, a manual check still works', () async {
      rig = await UpdateRig.create(
        firstCheckDelay: const Duration(milliseconds: 10),
        prefsValues: {'update.autoCheck': false, ..._noAutoInstall},
      );
      await rig.service.start();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(rig.manifestFetches, 0);
      expect(rig.service.state, UpdateState.idle);

      await rig.service.checkNow();
      expect(rig.manifestFetches, 1);
      expect(rig.service.state, UpdateState.available);
    });

    test('switching automatic checks on schedules one; off cancels it', () async {
      rig = await UpdateRig.create(
        firstCheckDelay: const Duration(milliseconds: 10),
        prefsValues: {'update.autoCheck': false, ..._noAutoInstall},
      );
      await rig.service.start();
      await rig.service.setAutoCheck(true);
      await waitUntil(() => rig.manifestFetches >= 1);

      final fetches = rig.manifestFetches;
      await rig.service.setAutoCheck(false);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(rig.manifestFetches, fetches);
    });

    test('settings use the update. key prefix and survive a new service', () async {
      rig = await UpdateRig.create();
      expect(rig.service.autoCheck, isTrue);
      expect(rig.service.autoInstall, isTrue);
      await rig.service.setAutoCheck(false);
      await rig.service.setAutoInstall(false);
      expect(rig.prefs.getBool('update.autoCheck'), isFalse);
      expect(rig.prefs.getBool('update.autoInstall'), isFalse);
      expect(rig.prefs.getKeys().every((k) => k.startsWith('update.')), isTrue);
    });

    test('turning autoInstall on while an update is available starts it', () async {
      rig = await UpdateRig.create(prefsValues: _noAutoInstall);
      await rig.service.start();
      await rig.service.checkNow();
      await rig.service.setAutoInstall(true);
      await waitUntil(() => rig.installer.installed.isNotEmpty);
    });

    test('the update flag and a version bump are reported once', () async {
      rig = await UpdateRig.create(prefsValues: {'update.lastRunVersion': '0.0.9'});
      await rig.service.start();
      expect(rig.service.justUpdatedVersion, '0.1.0');
      expect(rig.prefs.getString('update.lastRunVersion'), '0.1.0');
      rig.service.acknowledgeUpdated();
      expect(rig.service.justUpdatedVersion, isNull);
      await rig.dispose();

      rig = await UpdateRig.create(prefsValues: {'update.lastRunVersion': '0.1.0'});
      await rig.service.start();
      expect(rig.service.justUpdatedVersion, isNull);
      await rig.dispose();

      rig = await UpdateRig.create();
      await rig.service.start(updatedFlag: true);
      expect(rig.service.justUpdatedVersion, '0.1.0');
    });
  });

  group('download and install', () {
    test('autoInstall downloads and installs, then exits the app', () async {
      rig = await UpdateRig.create();
      await rig.service.start();
      await rig.service.checkNow();
      await waitUntil(() => rig.exits == 1);

      expect(rig.downloader.downloads, 1);
      expect(rig.installer.installed.single.path, startsWith(rig.dir.path));
      expect(rig.downloader.verifications, 1, reason: 'the file is re-verified right before installing');
      expect(rig.service.state, UpdateState.installing);
    });

    test('with autoInstall off the user starts the download', () async {
      rig = await UpdateRig.create(prefsValues: _noAutoInstall);
      await rig.service.start();
      await rig.service.checkNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(rig.installer.installed, isEmpty);

      final states = <UpdateState>[];
      rig.service.addListener(() => states.add(rig.service.state));
      await rig.service.downloadAndInstall();

      expect(rig.installer.installed, hasLength(1));
      expect(
        states.toSet(),
        containsAll([UpdateState.downloading, UpdateState.verifying, UpdateState.ready, UpdateState.installing]),
      );
      expect(rig.service.progress, isNull);
    });

    test('progress is exposed while downloading and cancel returns to available', () async {
      rig = await UpdateRig.create(prefsValues: _noAutoInstall);
      rig.downloader.gate = Completer<void>();
      await rig.service.start();
      await rig.service.checkNow();

      final run = rig.service.downloadAndInstall();
      await waitUntil(() => rig.service.state == UpdateState.downloading);
      expect(rig.service.progress!.fraction, closeTo(0.5, 0.01));

      rig.service.cancelDownload();
      await run;
      expect(rig.service.state, UpdateState.available);
      expect(rig.installer.installed, isEmpty);
    });

    test('download failures surface as an error and can be retried', () async {
      rig = await UpdateRig.create(prefsValues: _noAutoInstall);
      rig.downloader.downloadFailure = const UpdateException(UpdateErrorKind.hash, 'mismatch');
      await rig.service.start();
      await rig.service.checkNow();
      await rig.service.downloadAndInstall();

      expect(rig.service.state, UpdateState.error);
      expect(rig.service.errorPhase, UpdatePhase.download);
      expect(rig.service.error!.kind, UpdateErrorKind.hash);
      expect(rig.installer.installed, isEmpty, reason: 'a file that failed verification is never installed');

      rig.downloader.downloadFailure = null;
      await rig.service.downloadAndInstall();
      expect(rig.installer.installed, hasLength(1));
    });

    test('a file that fails the pre-install re-check is dropped and re-downloaded', () async {
      rig = await UpdateRig.create(prefsValues: _noAutoInstall);
      rig.downloader.verifyFailure = const UpdateException(UpdateErrorKind.hash, 'swapped on disk');
      await rig.service.start();
      await rig.service.checkNow();
      await rig.service.downloadAndInstall();

      expect(rig.service.state, UpdateState.error);
      expect(rig.service.errorPhase, UpdatePhase.install);
      expect(rig.installer.installed, isEmpty);

      rig.downloader.verifyFailure = null;
      await rig.service.downloadAndInstall();
      expect(rig.downloader.downloads, 2);
      expect(rig.installer.installed, hasLength(1));
    });
  });

  group('busy sessions', () {
    test('downloads while busy but installs only after notifyIdle', () async {
      rig = await UpdateRig.create();
      rig.busy = true;
      await rig.service.start();
      await rig.service.checkNow();
      await waitUntil(() => rig.service.state == UpdateState.ready && rig.service.waitingForIdle);

      expect(rig.downloader.downloads, 1);
      await Future<void>.delayed(const Duration(milliseconds: 120)); // several retry ticks
      expect(rig.installer.installed, isEmpty);
      expect(rig.service.state, UpdateState.ready);

      rig.busy = false;
      rig.service.notifyIdle();
      await waitUntil(() => rig.exits == 1);
      expect(rig.installer.installed, hasLength(1));
      expect(rig.service.waitingForIdle, isFalse);
    });

    test('the retry timer installs once the session is gone, even without notifyIdle', () async {
      rig = await UpdateRig.create();
      rig.busy = true;
      await rig.service.start();
      await rig.service.checkNow();
      await waitUntil(() => rig.service.waitingForIdle);

      rig.busy = false;
      await waitUntil(() => rig.installer.installed.isNotEmpty);
    });

    test('a session starting during the final verification still defers', () async {
      rig = await UpdateRig.create();
      rig.downloader.onVerify = () {
        if (rig.downloader.verifications == 1) rig.busy = true;
      };
      await rig.service.start();
      await rig.service.checkNow();
      await waitUntil(() => rig.service.state == UpdateState.ready && rig.service.waitingForIdle);
      expect(rig.installer.installed, isEmpty);

      rig.busy = false;
      rig.service.notifyIdle();
      await waitUntil(() => rig.installer.installed.isNotEmpty);
    });

    test('the app does not exit under a session that began after the installer started', () async {
      rig = await UpdateRig.create();
      rig.installer.onInstall = () => rig.busy = true;
      await rig.service.start();
      await rig.service.checkNow();
      await waitUntil(() => rig.installer.installed.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(rig.exits, 0);

      rig.busy = false;
      rig.service.notifyIdle();
      await waitUntil(() => rig.exits == 1);
    });
  });

  group('skipping', () {
    test('skip hides the version from automatic checks, a manual check shows it again', () async {
      rig = await UpdateRig.create(
        firstCheckDelay: const Duration(milliseconds: 15),
        checkInterval: const Duration(milliseconds: 30),
        prefsValues: _noAutoInstall,
      );
      await rig.service.checkNow();
      expect(rig.service.state, UpdateState.available);

      await rig.service.skip('0.2.0');
      expect(rig.service.state, UpdateState.idle);
      expect(rig.service.offer, isNull);
      expect(rig.service.skippedVersion, '0.2.0');
      expect(rig.prefs.getString('update.skippedVersion'), '0.2.0');

      final before = rig.manifestFetches;
      await rig.service.start();
      await waitUntil(() => rig.manifestFetches >= before + 2);
      expect(rig.service.state, UpdateState.idle, reason: 'automatic checks respect the skip');
      expect(rig.service.offer, isNull);

      await rig.service.checkNow();
      expect(rig.service.state, UpdateState.available);
      expect(rig.service.skippedVersion, isNull);
    });

    test('a newer release than the skipped one is offered', () async {
      rig = await UpdateRig.create(
        version: '0.3.0',
        prefsValues: {'update.skippedVersion': '0.2.0', ..._noAutoInstall},
        firstCheckDelay: const Duration(milliseconds: 10),
      );
      await rig.service.start();
      await waitUntil(() => rig.service.state == UpdateState.available);
    });

    test('skipping during a download aborts it and installs nothing', () async {
      rig = await UpdateRig.create(prefsValues: _noAutoInstall);
      rig.downloader.gate = Completer<void>();
      await rig.service.start();
      await rig.service.checkNow();
      final run = rig.service.downloadAndInstall();
      await waitUntil(() => rig.service.state == UpdateState.downloading);

      await rig.service.skip('0.2.0');
      await run;
      expect(rig.service.state, UpdateState.idle);
      expect(rig.service.offer, isNull);
      expect(rig.installer.installed, isEmpty);
    });
  });

  group('platforms that need someone at the screen', () {
    test('an automatic update waits for "install now"', () async {
      rig = await UpdateRig.create(confirm: true);
      await rig.service.start();
      await rig.service.checkNow();
      await waitUntil(() => rig.service.state == UpdateState.ready);

      expect(rig.service.awaitingConfirmation, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(rig.installer.installed, isEmpty, reason: 'no UAC/polkit prompt appears unannounced');

      await rig.service.downloadAndInstall();
      expect(rig.installer.installed, hasLength(1));
      expect(rig.downloader.downloads, 1);
    });

    test('clicking Update on an available release needs no second confirmation', () async {
      rig = await UpdateRig.create(confirm: true, prefsValues: _noAutoInstall);
      await rig.service.start();
      await rig.service.checkNow();
      await rig.service.downloadAndInstall();
      expect(rig.installer.installed, hasLength(1));
    });

    test('declining the elevation prompt keeps the app and the file, retry works', () async {
      rig = await UpdateRig.create(confirm: true, prefsValues: _noAutoInstall);
      rig.installer.script
        ..clear()
        ..addAll([
          const UpdateException(UpdateErrorKind.elevationDenied, 'declined'),
          const InstallResult.restart(),
        ]);
      await rig.service.start();
      await rig.service.checkNow();
      await rig.service.downloadAndInstall();

      expect(rig.service.state, UpdateState.error);
      expect(rig.service.error!.kind, UpdateErrorKind.elevationDenied);
      expect(rig.exits, 0);

      await rig.service.downloadAndInstall();
      expect(rig.installer.installed, hasLength(2));
      expect(rig.downloader.downloads, 1, reason: 'the verified file is reused');
      await waitUntil(() => rig.exits == 1);
    });

    test('manual install required, then Continue hands off to the system installer', () async {
      rig = await UpdateRig.create(confirm: true, prefsValues: _noAutoInstall);
      rig.installer.script
        ..clear()
        ..addAll([
          const InstallResult.manual(ManualInstallReason.installPermission, location: '/data/updates/a.apk'),
          const InstallResult.handedOff(),
        ]);
      await rig.service.start();
      await rig.service.checkNow();
      await rig.service.downloadAndInstall();

      expect(rig.service.state, UpdateState.manualInstallRequired);
      expect(rig.service.manualReason, ManualInstallReason.installPermission);
      expect(rig.service.manualLocation, '/data/updates/a.apk');

      await rig.service.downloadAndInstall();
      expect(rig.service.state, UpdateState.installing);
      expect(rig.exits, 0, reason: 'the system installer replaces the app by itself');

      // Installer dismissed: the button comes back.
      await waitUntil(() => rig.service.state == UpdateState.ready);
      expect(rig.service.awaitingConfirmation, isTrue);
      expect(rig.downloader.downloads, 1);
    });
  });
}
