import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/update/manifest.dart';
import 'package:thelxis/update/manifest_loader.dart';
import 'package:thelxis/update/update_exception.dart';
import 'package:thelxis/update/update_target.dart';
import 'package:thelxis/update/update_trust.dart';

import 'support/update_fakes.dart';

void main() {
  late TestSigner signer;
  setUpAll(() async => signer = await TestSigner.create());

  Future<UpdateManifest> load(Uint8List manifest, {Uint8List? signature, TestSigner? verifyWith}) {
    final loader = ManifestLoader(
      fetch: staticFetcher(manifest: manifest, signature: signature),
      verifier: ed25519Verifier(publicKey: (verifyWith ?? signer).publicKey),
    );
    return loader.load();
  }

  Future<UpdateErrorKind> failureOf(Future<Object?> future) async {
    try {
      await future;
    } on UpdateException catch (e) {
      return e.kind;
    }
    fail('expected an UpdateException');
  }

  group('signature verification', () {
    test('accepts a valid signature (with CI trailing newline) and parses', () async {
      final bytes = manifestBytes();
      final manifest = await load(bytes, signature: await signer.signatureFile(bytes));
      expect(manifest.version.toString(), '0.2.0');
      expect(manifest.notesUrl.toString(), contains('/releases/tag/v0.2.0'));
      expect(manifest.assets.keys, contains('windows-x64'));
    });

    test('rejects a tampered manifest byte', () async {
      final bytes = manifestBytes();
      final sig = await signer.signatureFile(bytes);
      final tampered = Uint8List.fromList(bytes)..[bytes.length ~/ 2] ^= 0x01;
      expect(await failureOf(load(tampered, signature: sig)), UpdateErrorKind.signatureInvalid);
    });

    test('rejects a signature made by another key', () async {
      final other = await TestSigner.create();
      final bytes = manifestBytes();
      expect(
        await failureOf(load(bytes, signature: await other.signatureFile(bytes))),
        UpdateErrorKind.signatureInvalid,
      );
    });

    test('a missing signature file is its own error and never falls back', () async {
      expect(await failureOf(load(manifestBytes())), UpdateErrorKind.signatureMissing);
    });

    test('malformed signature files are rejected', () async {
      final bytes = manifestBytes();
      for (final garbage in ['', 'not base64 !!!', 'AAAA']) {
        expect(
          await failureOf(load(bytes, signature: Uint8List.fromList(utf8.encode(garbage)))),
          UpdateErrorKind.signatureInvalid,
          reason: 'signature "$garbage"',
        );
      }
    });

    test('the signature is verified before the manifest is parsed', () async {
      final garbage = Uint8List.fromList(utf8.encode('{ not json'));
      // Unsigned garbage must fail on the signature, not on parsing.
      expect(
        await failureOf(load(garbage, signature: await TestSigner.create().then((s) => s.signatureFile(garbage)))),
        UpdateErrorKind.signatureInvalid,
      );
      // Correctly signed garbage fails on parsing.
      expect(await failureOf(load(garbage, signature: await signer.signatureFile(garbage))), UpdateErrorKind.manifest);
    });

    test('the embedded release key is a valid Ed25519 public key', () {
      final verify = ed25519Verifier();
      expect(verify(Uint8List(8), Uint8List(64)), completion(isFalse));
      expect(UpdateTrust.publicKey, hasLength(43));
    });

    test('a wrong-length key or signature never verifies', () async {
      expect(await ed25519Verifier(publicKey: 'AAAA')([1], List.filled(64, 0)), isFalse);
      expect(await ed25519Verifier(publicKey: signer.publicKey)([1], [1, 2, 3]), isFalse);
    });
  });

  group('manifest parsing', () {
    test('rejects other manifest formats and missing versions', () {
      expect(() => UpdateManifest.parse(manifestBytes(v: 2)), throwsA(isA<UpdateException>()));
      expect(() => UpdateManifest.parse(manifestBytes(version: 'banana')), throwsA(isA<UpdateException>()));
      expect(() => UpdateManifest.parse(utf8.encode('[]')), throwsA(isA<UpdateException>()));
    });

    test('drops malformed assets without failing the manifest', () {
      final manifest = UpdateManifest.parse(manifestBytes(assets: {
        'windows-x64': assetJson('good.exe', [1, 2, 3]),
        'macos-universal': {...assetJson('bad.dmg', [1]), 'sha256': 'xyz'},
        'linux-x64-deb': {...assetJson('http.deb', [1]), 'url': 'http://insecure.example/x.deb'},
        'linux-x64-tar': {...assetJson('zero.tgz', [1]), 'size': 0},
        'android-universal': 'nope',
      }));
      expect(manifest.assets.keys, ['windows-x64']);
    });

    test('lowercases hashes and keeps only https notes links', () {
      final upper = sha256Hex([1]).toUpperCase();
      final manifest = UpdateManifest.parse(manifestBytes(
        assets: {'windows-x64': assetJson('a.exe', [1], sha: upper)},
        notesUrl: 'http://example.com/notes',
      ));
      expect(manifest.assets['windows-x64']!.sha256, upper.toLowerCase());
      expect(manifest.notesUrl, isNull);
    });

    test('file names cannot escape the update directory', () {
      UpdateAsset named(String name) => UpdateAsset(
            name: name,
            url: Uri.parse('https://x.example/f'),
            size: 1,
            sha256: sha256Hex([1]),
          );
      expect(named('../../etc/passwd').fileName, 'passwd');
      expect(named(r'..\..\evil.exe').fileName, 'evil.exe');
      expect(named('.hidden').fileName, 'hidden');
      expect(named('we ird*name?.exe').fileName, 'we_ird_name_.exe');
      expect(named('///').fileName, 'update.bin');
    });
  });

  group('version comparison', () {
    SemVer v(String s) => SemVer.tryParse(s)!;

    test('compares numerically, not lexically', () {
      expect(v('0.1.9').compareCore(v('0.1.10')), lessThan(0));
      expect(v('0.2.0').compareCore(v('0.1.99')), greaterThan(0));
      expect(v('1.0.0').compareCore(v('0.99.99')), greaterThan(0));
      expect(v('0.2.0').compareCore(v('0.2.0')), 0);
    });

    test('parses build metadata, v prefix and pre-releases', () {
      expect(v('v1.2.3').toString(), '1.2.3');
      expect(v('1.2.3+45').toString(), '1.2.3');
      expect(v('1.2.3-rc.1').isPreRelease, isTrue);
      expect(SemVer.tryParse('1.2'), isNull);
      expect(SemVer.tryParse('a.b.c'), isNull);
      expect(SemVer.tryParse(null), isNull);
    });

    test('isNewerThan offers only higher final releases', () {
      UpdateManifest m(String version) => UpdateManifest.parse(manifestBytes(version: version));
      expect(m('0.1.10').isNewerThan(v('0.1.9')), isTrue);
      expect(m('0.1.9').isNewerThan(v('0.1.10')), isFalse);
      expect(m('0.1.0').isNewerThan(v('0.1.0')), isFalse);
      expect(m('0.3.0-rc.1').isNewerThan(v('0.2.0')), isFalse, reason: 'pre-releases are ignored');
      // A pre-release build of 0.2.0 counts as 0.2.0, so 0.2.0 is not an update.
      expect(m('0.2.0').isNewerThan(v('0.2.0-rc.1')), isFalse);
      expect(m('0.2.1').isNewerThan(v('0.2.0-rc.1')), isTrue);
    });
  });

  group('asset selection', () {
    final manifest = UpdateManifest.parse(manifestBytes());

    String? keyFor(UpdateTarget target, [UpdateManifest? m]) {
      final asset = (m ?? manifest).assetFor(target);
      if (asset == null) return null;
      return (m ?? manifest).assets.entries.firstWhere((e) => identical(e.value, asset)).key;
    }

    test('desktop platforms', () {
      expect(keyFor(const UpdateTarget(os: UpdateOs.windows)), 'windows-x64');
      expect(keyFor(const UpdateTarget(os: UpdateOs.macos)), 'macos-universal');
      expect(keyFor(const UpdateTarget(os: UpdateOs.linux, linuxDeb: true)), 'linux-x64-deb');
      expect(keyFor(const UpdateTarget(os: UpdateOs.linux)), 'linux-x64-tar');
    });

    test('android prefers the first supported ABI that has an asset', () {
      expect(
        keyFor(const UpdateTarget(os: UpdateOs.android, androidAbis: ['arm64-v8a', 'armeabi-v7a', 'armeabi'])),
        'android-arm64-v8a',
      );
      expect(
        keyFor(const UpdateTarget(os: UpdateOs.android, androidAbis: ['armeabi-v7a', 'armeabi'])),
        'android-armeabi-v7a',
      );
      expect(
        keyFor(const UpdateTarget(os: UpdateOs.android, androidAbis: ['x86_64', 'x86'])),
        'android-x86_64',
      );
    });

    test('android falls back to the universal APK', () {
      expect(keyFor(const UpdateTarget(os: UpdateOs.android, androidAbis: ['mips', 'riscv64'])), 'android-universal');
      expect(keyFor(const UpdateTarget(os: UpdateOs.android)), 'android-universal');

      final noArm64 = UpdateManifest.parse(manifestBytes(assets: {
        'android-armeabi-v7a': assetJson('v7.apk', [1]),
        'android-universal': assetJson('uni.apk', [1]),
      }));
      expect(keyFor(const UpdateTarget(os: UpdateOs.android, androidAbis: ['arm64-v8a', 'armeabi-v7a']), noArm64),
          'android-armeabi-v7a');
    });

    test('a missing asset or an unsupported platform yields null', () {
      final onlyWindows = UpdateManifest.parse(manifestBytes(assets: {'windows-x64': assetJson('a.exe', [1])}));
      expect(onlyWindows.assetFor(const UpdateTarget(os: UpdateOs.macos)), isNull);
      expect(manifest.assetFor(const UpdateTarget(os: UpdateOs.unsupported)), isNull);
      // A .deb install never silently falls back to the tarball.
      final tarOnly = UpdateManifest.parse(manifestBytes(assets: {'linux-x64-tar': assetJson('a.tgz', [1])}));
      expect(tarOnly.assetFor(const UpdateTarget(os: UpdateOs.linux, linuxDeb: true)), isNull);
    });

    test('target detection with injected probes', () async {
      final android = await UpdateTarget.detect(os: UpdateOs.android, androidAbis: () async => ['x86_64']);
      expect(android.androidAbis, ['x86_64']);
      final deb = await UpdateTarget.detect(os: UpdateOs.linux, linuxDeb: () async => true);
      expect(deb.linuxDeb, isTrue);
    });

    test('deb detection needs /opt/thelxis and package ownership', () async {
      Future<bool> detect(String exe, {bool listExists = false, int dpkgExit = 1}) => isInstalledFromDeb(
            executable: exe,
            fileExists: (_) => listExists,
            run: (cmd, args) async => stubResult(dpkgExit),
          );
      expect(await detect('/opt/thelxis/thelxis', listExists: true), isTrue);
      expect(await detect('/opt/thelxis/thelxis', dpkgExit: 0), isTrue);
      expect(await detect('/opt/thelxis/thelxis'), isFalse);
      expect(await detect('/home/u/Thelxis/thelxis', listExists: true, dpkgExit: 0), isFalse);
    });
  });
}
