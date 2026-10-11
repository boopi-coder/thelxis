import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:cryptography/cryptography.dart';

import 'manifest.dart';
import 'update_exception.dart';
import 'update_http.dart';

class DownloadProgress {
  const DownloadProgress({required this.received, required this.total, this.bytesPerSecond = 0});

  final int received;
  final int total;
  final double bytesPerSecond;

  double get fraction => total <= 0 ? 0 : (received / total).clamp(0.0, 1.0);
}

typedef DownloadProgressCallback = void Function(DownloadProgress progress);

/// Lowercase hex SHA-256 of the file at [path].
typedef FileHasher = Future<String> Function(String path);

/// Hashes in a background isolate so a 100 MB installer never janks the UI.
Future<String> sha256OfFile(String path) => Isolate.run(() async {
      final sink = Sha256().newHashSink();
      await for (final chunk in File(path).openRead()) {
        sink.add(chunk);
      }
      sink.close();
      final digest = await sink.hash();
      final out = StringBuffer();
      for (final b in digest.bytes) {
        out.write(b.toRadixString(16).padLeft(2, '0'));
      }
      return out.toString();
    });

/// Streams a release asset to disk and proves it matches the signed manifest
/// (exact size and SHA-256) before anyone is allowed to install it.
///
/// Data lands in `<name>.part`; an interrupted download is resumed with a
/// `Range` request when the server supports it (otherwise it restarts) and
/// the finished file is only ever renamed into place after verification.
class UpdateDownloader {
  UpdateDownloader({
    UpdateHttp? http,
    this.progressInterval = const Duration(milliseconds: 100),
    this.maxAttempts = 3,
    this.retryDelay = const Duration(seconds: 2),
    FileHasher? hasher,
  })  : _http = http ?? UpdateHttp(),
        _hash = hasher ?? sha256OfFile;

  final UpdateHttp _http;
  final Duration progressInterval;

  /// Tries per [download] for transient network failures (each resumes).
  final int maxAttempts;
  final Duration retryDelay;
  final FileHasher _hash;

  /// Downloads [asset] into [dir] and returns the verified file.
  ///
  /// A complete, valid file from an earlier run is reused without any network
  /// access. [onVerifying] fires once the bytes are on disk and hashing starts.
  Future<File> download(
    UpdateAsset asset, {
    required Directory dir,
    DownloadProgressCallback? onProgress,
    void Function()? onVerifying,
    UpdateCancelToken? cancel,
  }) async {
    await _prepareDir(dir);
    final sep = Platform.pathSeparator;
    final target = File('${dir.path}$sep${asset.fileName}');
    final part = File('${target.path}.part');

    if (await target.exists()) {
      try {
        onVerifying?.call();
        await verifyFile(target, asset);
        onProgress?.call(DownloadProgress(received: asset.size, total: asset.size));
        return target;
      } on UpdateException {
        await _deleteQuietly(target);
      }
    }

    for (var attempt = 1;; attempt++) {
      cancel?.throwIfCancelled();
      try {
        await _fetchInto(part, asset, onProgress, cancel);
        break;
      } on UpdateException catch (e) {
        final transient = e.kind == UpdateErrorKind.network || (e.status != null && e.status! >= 500);
        if (!transient || attempt >= maxAttempts || (cancel?.isCancelled ?? false)) rethrow;
        await Future<void>.delayed(retryDelay);
      }
    }

    onVerifying?.call();
    try {
      await verifyFile(part, asset);
    } on UpdateException {
      await _deleteQuietly(part);
      rethrow;
    }
    try {
      await part.rename(target.path);
    } on FileSystemException catch (e) {
      throw UpdateException(UpdateErrorKind.storage, 'cannot finalize download: ${e.message}', cause: e);
    }
    return target;
  }

  /// Checks size then SHA-256 of [file] against [asset]. When [deleteOnFailure]
  /// is set a file that fails is removed so it can never be installed later.
  Future<void> verifyFile(File file, UpdateAsset asset, {bool deleteOnFailure = false}) async {
    try {
      final int length;
      try {
        length = await file.length();
      } on FileSystemException catch (e) {
        throw UpdateException(UpdateErrorKind.storage, 'update file unreadable: ${e.message}', cause: e);
      }
      if (length != asset.size) {
        throw UpdateException(UpdateErrorKind.size, 'size $length, expected ${asset.size}');
      }
      final actual = await _hash(file.path);
      if (actual != asset.sha256) {
        throw const UpdateException(UpdateErrorKind.hash, 'SHA-256 does not match the signed manifest');
      }
    } on UpdateException {
      if (deleteOnFailure) await _deleteQuietly(file);
      rethrow;
    }
  }

  /// Removes stale installers from [dir]: everything when [all], otherwise only
  /// files not modified for [maxAge]. Best effort.
  Future<void> cleanup(Directory dir, {bool all = false, Duration maxAge = const Duration(days: 7)}) async {
    try {
      if (!await dir.exists()) return;
      final cutoff = DateTime.now().subtract(maxAge);
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        if (all || (await entity.lastModified()).isBefore(cutoff)) {
          await _deleteQuietly(entity);
        }
      }
    } on FileSystemException {
      // Housekeeping only.
    }
  }

  Future<void> _fetchInto(
    File part,
    UpdateAsset asset,
    DownloadProgressCallback? onProgress,
    UpdateCancelToken? cancel,
  ) async {
    var offset = 0;
    try {
      if (await part.exists()) offset = await part.length();
      if (offset > asset.size) {
        await part.delete();
        offset = 0;
      }
    } on FileSystemException catch (e) {
      throw UpdateException(UpdateErrorKind.storage, 'cannot access ${part.path}: ${e.message}', cause: e);
    }
    if (offset == asset.size) {
      onProgress?.call(DownloadProgress(received: offset, total: asset.size));
      return; // complete from an earlier run; the caller verifies it
    }

    await _http.get<void>(
      asset.url,
      (response) async {
        final status = response.statusCode;
        var resume = false;
        if (status == HttpStatus.partialContent) {
          if (_contentRangeStart(response.headers.value(HttpHeaders.contentRangeHeader)) != offset) {
            await _deleteQuietly(part);
            throw const UpdateException(UpdateErrorKind.network, 'unexpected Content-Range, restarting');
          }
          resume = true;
        } else if (status == HttpStatus.ok) {
          offset = 0; // the server ignored Range (or none was sent): start over
        } else if (status == HttpStatus.requestedRangeNotSatisfiable) {
          await _deleteQuietly(part);
          throw const UpdateException(UpdateErrorKind.network, 'range not satisfiable, restarting');
        } else {
          await response.drain<void>().timeout(_http.headersTimeout);
          throw UpdateException(UpdateErrorKind.http, 'HTTP $status for ${asset.url.host}', status: status);
        }

        final expectedBody = asset.size - offset;
        final declared = response.contentLength;
        if (declared >= 0 && declared != expectedBody) {
          if (!resume) await _deleteQuietly(part);
          throw UpdateException(
            UpdateErrorKind.size,
            'server announces $declared bytes, manifest implies $expectedBody',
          );
        }

        RandomAccessFile? raf;
        try {
          raf = await part.open(mode: resume ? FileMode.append : FileMode.write);
          var received = offset;
          final clock = Stopwatch()..start();
          var lastEmit = Duration.zero;
          var lastEmitBytes = received;
          await for (final chunk in response.timeout(_http.idleTimeout)) {
            received += chunk.length;
            if (received > asset.size) {
              throw UpdateException(UpdateErrorKind.size, 'more than ${asset.size} bytes received');
            }
            await raf.writeFrom(chunk);
            final now = clock.elapsed;
            if (onProgress != null && now - lastEmit >= progressInterval) {
              final seconds = (now - lastEmit).inMicroseconds / Duration.microsecondsPerSecond;
              onProgress(DownloadProgress(
                received: received,
                total: asset.size,
                bytesPerSecond: seconds > 0 ? (received - lastEmitBytes) / seconds : 0,
              ));
              lastEmit = now;
              lastEmitBytes = received;
            }
          }
          await raf.flush();
          onProgress?.call(DownloadProgress(received: received, total: asset.size));
        } on FileSystemException catch (e) {
          throw UpdateException(UpdateErrorKind.storage, 'cannot write update: ${e.message}', cause: e);
        } finally {
          await raf?.close();
        }
      },
      headers: offset > 0 ? {HttpHeaders.rangeHeader: 'bytes=$offset-'} : const {},
      cancel: cancel,
    ).onError<UpdateException>((e, _) async {
      // A size violation poisons the partial file; a network blip keeps it for resume.
      if (e.kind == UpdateErrorKind.size) await _deleteQuietly(part);
      throw e;
    });

    // A short body that ended cleanly is a size mismatch, not a resumable cut.
    final length = await part.length();
    if (length != asset.size) {
      await _deleteQuietly(part);
      throw UpdateException(UpdateErrorKind.size, 'received $length bytes, expected ${asset.size}');
    }
  }

  static int? _contentRangeStart(String? header) {
    final m = header == null ? null : RegExp(r'^bytes (\d+)-').firstMatch(header.trim());
    return m == null ? null : int.tryParse(m[1]!);
  }

  static Future<void> _prepareDir(Directory dir) async {
    try {
      await dir.create(recursive: true);
    } on FileSystemException catch (e) {
      throw UpdateException(UpdateErrorKind.storage, 'cannot create ${dir.path}: ${e.message}', cause: e);
    }
    if (Platform.isWindows) return;
    try {
      // The installer is run with elevated rights later; keep other users out.
      await Process.run('chmod', ['700', dir.path]);
    } on ProcessException {
      // Best effort, like the identity file.
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Nothing more to do.
    }
  }
}
