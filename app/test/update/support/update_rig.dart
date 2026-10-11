import 'dart:io';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/update/manifest_loader.dart';
import 'package:thelxis/update/manifest.dart';
import 'package:thelxis/update/update_exception.dart';
import 'package:thelxis/update/update_service.dart';

import 'update_fakes.dart';

/// A service wired to fakes: signed manifests from memory, a downloader that
/// writes a stub file, an installer that records instead of installing.
class UpdateRig {
  UpdateRig._();

  late TestSigner signer;
  late UpdateService service;
  late FakeDownloader downloader;
  late FakeInstaller installer;
  late Directory dir;
  late SharedPreferences prefs;

  Uint8List manifest = manifestBytes();
  bool failNetwork = false;
  bool busy = false;
  int manifestFetches = 0;
  int exits = 0;

  static Future<UpdateRig> create({
    String current = '0.1.0',
    String version = '0.2.0',
    bool confirm = false,
    Map<String, Object> prefsValues = const {},
    Duration firstCheckDelay = const Duration(hours: 1),
    Duration checkInterval = const Duration(hours: 1),
    Duration busyRetryInterval = const Duration(milliseconds: 30),
    Duration handoffGrace = const Duration(milliseconds: 60),
    bool wrongKey = false,
  }) async {
    final rig = UpdateRig._();
    rig.signer = await TestSigner.create();
    rig.manifest = manifestBytes(version: version);
    rig.dir = await Directory.systemTemp.createTemp('thelxis-service-test-');
    SharedPreferences.setMockInitialValues(prefsValues);
    rig.prefs = await SharedPreferences.getInstance();
    rig.downloader = FakeDownloader();
    rig.installer = FakeInstaller(confirm: confirm);

    final verifyKey = wrongKey ? (await TestSigner.create()).publicKey : rig.signer.publicKey;
    final loader = ManifestLoader(
      fetch: (url, {required maxBytes}) async {
        if (rig.failNetwork) throw const UpdateException(UpdateErrorKind.network, 'offline');
        if (url.path.endsWith('.sig')) return rig.signer.signatureFile(rig.manifest);
        rig.manifestFetches++;
        return rig.manifest;
      },
      verifier: ed25519Verifier(publicKey: verifyKey),
    );
    final deps = fakeDependencies(
      loader: loader,
      downloader: rig.downloader,
      installer: rig.installer,
      dir: rig.dir,
      currentVersion: current,
    );
    rig.service = UpdateService(
      prefs: rig.prefs,
      isBusy: () => rig.busy,
      dependencies: () async => deps,
      exitApp: () => rig.exits++,
      firstCheckDelay: firstCheckDelay,
      checkInterval: checkInterval,
      busyRetryInterval: busyRetryInterval,
      exitDelay: Duration.zero,
      handoffGrace: handoffGrace,
    );
    return rig;
  }

  Future<void> dispose() async {
    service.dispose();
    await dir.delete(recursive: true);
  }
}
