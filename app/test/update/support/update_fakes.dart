import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:thelxis/core/base64url.dart';
import 'package:thelxis/update/downloader.dart';
import 'package:thelxis/update/installers/installer.dart';
import 'package:thelxis/update/manifest.dart';
import 'package:thelxis/update/manifest_loader.dart';
import 'package:thelxis/update/update_dependencies.dart';
import 'package:thelxis/update/update_exception.dart';
import 'package:thelxis/update/update_target.dart';

/// A throw-away Ed25519 release key for tests.
class TestSigner {
  TestSigner._(this._pair, this.publicKey);

  final SimpleKeyPair _pair;
  final String publicKey;

  static Future<TestSigner> create() async {
    final pair = await Ed25519().newKeyPair();
    final pub = await pair.extractPublicKey();
    return TestSigner._(pair, b64uEncode(pub.bytes));
  }

  Future<Uint8List> sign(List<int> message) async {
    final sig = await Ed25519().sign(message, keyPair: _pair);
    return Uint8List.fromList(sig.bytes);
  }

  /// `update.json.sig` content: base64url plus the trailing newline CI writes.
  Future<Uint8List> signatureFile(List<int> message) async =>
      Uint8List.fromList(utf8.encode('${b64uEncode(await sign(message))}\n'));
}

ProcessResult stubResult(int exitCode, {String out = '', String err = ''}) =>
    ProcessResult(0, exitCode, out, err);

String sha256Hex(List<int> bytes) {
  final out = StringBuffer();
  for (final b in Sha256().toSync().hashSync(bytes).bytes) {
    out.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

Map<String, dynamic> assetJson(String name, List<int> payload, {String? sha, int? size}) => {
      'name': name,
      'url': 'https://github.com/sibawal/thelxis/releases/download/v0.2.0/$name',
      'size': size ?? payload.length,
      'sha256': sha ?? sha256Hex(payload),
    };

Uint8List manifestBytes({
  String version = '0.2.0',
  Map<String, Object?>? assets,
  Object? v = 1,
  String notesUrl = 'https://github.com/sibawal/thelxis/releases/tag/v0.2.0',
}) {
  final payload = Uint8List.fromList(List<int>.generate(64, (i) => i));
  return Uint8List.fromList(utf8.encode(jsonEncode({
    'v': v,
    'version': version,
    'published': '2026-10-20T10:00:00Z',
    'notes_url': notesUrl,
    'assets': assets ??
        {
          'windows-x64': assetJson('Thelxis-$version-windows-x64-setup.exe', payload),
          'macos-universal': assetJson('Thelxis-$version-macos-universal.dmg', payload),
          'linux-x64-deb': assetJson('thelxis_${version}_amd64.deb', payload),
          'linux-x64-tar': assetJson('Thelxis-$version-linux-x64.tar.gz', payload),
          'android-arm64-v8a': assetJson('Thelxis-$version-android-arm64-v8a.apk', payload),
          'android-armeabi-v7a': assetJson('Thelxis-$version-android-armeabi-v7a.apk', payload),
          'android-x86_64': assetJson('Thelxis-$version-android-x86_64.apk', payload),
          'android-universal': assetJson('Thelxis-$version-android-universal.apk', payload),
        },
  })));
}

/// Serves the given bytes for the manifest and signature URLs; a null
/// signature answers 404 like a release without `update.json.sig`.
BytesFetcher staticFetcher({required Uint8List manifest, Uint8List? signature}) {
  return (url, {required maxBytes}) async {
    if (url.path.endsWith('update.json.sig')) {
      if (signature == null) {
        throw const UpdateException(UpdateErrorKind.http, 'HTTP 404', status: 404);
      }
      return signature;
    }
    return manifest;
  };
}

/// Loader whose manifest is signed by [signer] (and verified with it).
Future<ManifestLoader> signedLoader(TestSigner signer, Uint8List manifest) async {
  return ManifestLoader(
    fetch: staticFetcher(manifest: manifest, signature: await signer.signatureFile(manifest)),
    verifier: ed25519Verifier(publicKey: signer.publicKey),
  );
}

/// Downloader that never touches the network.
class FakeDownloader extends UpdateDownloader {
  FakeDownloader({this.payload = const [1, 2, 3]}) : super(retryDelay: Duration.zero);

  final List<int> payload;
  int downloads = 0;
  int verifications = 0;
  UpdateException? downloadFailure;
  UpdateException? verifyFailure;

  /// When set, [download] waits for it (or for cancellation).
  Completer<void>? gate;

  /// Runs at the start of every [verifyFile] call.
  void Function()? onVerify;

  @override
  Future<File> download(
    UpdateAsset asset, {
    required Directory dir,
    DownloadProgressCallback? onProgress,
    void Function()? onVerifying,
    UpdateCancelToken? cancel,
  }) async {
    downloads++;
    onProgress?.call(DownloadProgress(received: asset.size ~/ 2, total: asset.size));
    final g = gate;
    if (g != null) {
      final cancelled = Completer<void>();
      cancel?.onCancel(() => cancelled.complete());
      await Future.any([g.future, cancelled.future]);
      cancel?.throwIfCancelled();
    }
    onVerifying?.call();
    final failure = downloadFailure;
    if (failure != null) throw failure;
    await dir.create(recursive: true);
    final file = File('${dir.path}/${asset.fileName}');
    await file.writeAsBytes(payload);
    return file;
  }

  @override
  Future<void> verifyFile(File file, UpdateAsset asset, {bool deleteOnFailure = false}) async {
    verifications++;
    onVerify?.call();
    final failure = verifyFailure;
    if (failure != null) {
      if (deleteOnFailure && file.existsSync()) file.deleteSync();
      throw failure;
    }
  }

  @override
  Future<void> cleanup(Directory dir, {bool all = false, Duration maxAge = const Duration(days: 7)}) async {}
}

/// Installer that records calls instead of installing anything.
class FakeInstaller implements UpdateInstaller {
  FakeInstaller({this.confirm = false});

  final bool confirm;
  final List<File> installed = [];

  /// Runs at the start of every [install] call.
  void Function()? onInstall;

  /// Results returned in order; the last one repeats. Exceptions are thrown.
  final List<Object> script = [const InstallResult.restart()];

  @override
  bool get requiresUserConfirmation => confirm;

  @override
  Future<InstallResult> install(File file, UpdateAsset asset) async {
    installed.add(file);
    onInstall?.call();
    final index = installed.length - 1 < script.length ? installed.length - 1 : script.length - 1;
    final next = script[index];
    if (next is Exception) throw next;
    return next as InstallResult;
  }
}

UpdateDependencies fakeDependencies({
  required ManifestLoader loader,
  required UpdateDownloader downloader,
  required UpdateInstaller installer,
  required Directory dir,
  String currentVersion = '0.1.0',
  UpdateTarget target = const UpdateTarget(os: UpdateOs.windows),
}) {
  return UpdateDependencies(
    currentVersion: currentVersion,
    loader: loader,
    downloader: downloader,
    installer: installer,
    target: target,
    downloadDir: dir,
  );
}

/// Polls until [condition] holds (real time; the timers under test are tiny).
Future<void> waitUntil(bool Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Records every command instead of running it.
class FakeProcessLauncher implements ProcessLauncher {
  /// Each entry is `[executable, ...args]`.
  final List<List<String>> runs = [];
  final List<List<String>> detached = [];

  /// Decides the result of a command; may throw [ProcessException].
  ProcessResult Function(String executable, List<String> args)? onRun;

  @override
  Future<ProcessResult> run(String executable, List<String> args) async {
    runs.add([executable, ...args]);
    return onRun?.call(executable, args) ?? stubResult(0);
  }

  @override
  Future<void> startDetached(String executable, List<String> args) async {
    detached.add([executable, ...args]);
  }
}
