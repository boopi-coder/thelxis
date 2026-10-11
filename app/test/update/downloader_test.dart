import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/update/downloader.dart';
import 'package:thelxis/update/manifest.dart';
import 'package:thelxis/update/update_exception.dart';
import 'package:thelxis/update/update_http.dart';

import 'support/update_fakes.dart';

/// Serves [handler] on a loopback port and records the requests.
class _Server {
  _Server._(this._http, this.handler) {
    _http.listen((request) async {
      requests.add(request.uri.path);
      rangeHeaders.add(request.headers.value(HttpHeaders.rangeHeader));
      userAgents.add(request.headers.value(HttpHeaders.userAgentHeader));
      try {
        await handler(request);
      } on Object {
        // The client may hang up (cancel / interruption tests).
      }
    });
  }

  final HttpServer _http;
  Future<void> Function(HttpRequest request) handler;
  final List<String> requests = [];
  final List<String?> rangeHeaders = [];
  final List<String?> userAgents = [];

  static Future<_Server> start(Future<void> Function(HttpRequest) handler) async =>
      _Server._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), handler);

  Uri url(String path) => Uri.parse('http://127.0.0.1:${_http.port}$path');
  Future<void> close() => _http.close(force: true);
}

void main() {
  late Directory tmp;
  late _Server server;
  late Uint8List payload;
  late UpdateAsset asset;

  UpdateDownloader downloader({int attempts = 3}) => UpdateDownloader(
        http: UpdateHttp(userAgent: 'Thelxis/9.9.9', idleTimeout: const Duration(seconds: 3)),
        progressInterval: Duration.zero,
        maxAttempts: attempts,
        retryDelay: Duration.zero,
      );

  Future<void> serveFull(
    HttpRequest request, {
    List<int>? body,
    int chunk = 16 * 1024,
    Duration pause = Duration.zero,
  }) async {
    final data = body ?? payload;
    request.response.contentLength = data.length;
    for (var i = 0; i < data.length; i += chunk) {
      request.response.add(data.sublist(i, i + chunk > data.length ? data.length : i + chunk));
      await request.response.flush();
      if (pause > Duration.zero) await Future<void>.delayed(pause);
    }
    await request.response.close();
  }

  /// Promises the whole body, sends [sent] bytes and drops the connection.
  Future<void> serveTruncated(HttpRequest request, int sent) async {
    request.response.contentLength = payload.length;
    request.response.add(payload.sublist(0, sent));
    await request.response.flush();
    await request.response.close(); // fewer bytes than promised: dart:io destroys the socket
  }

  Future<UpdateException> failureOf(Future<Object?> future) async {
    try {
      await future;
    } on UpdateException catch (e) {
      return e;
    }
    fail('expected an UpdateException');
  }

  List<String> filesIn(Directory dir) =>
      dir.listSync().map((e) => e.path.split(Platform.pathSeparator).last).toList()..sort();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('thelxis-dl-test-');
    payload = Uint8List.fromList(List<int>.generate(200 * 1024 + 123, (i) => (i * 31 + 7) & 0xff));
    server = await _Server.start((r) => serveFull(r, pause: const Duration(milliseconds: 4)));
    asset = UpdateAsset(
      name: 'Thelxis-0.2.0-linux-x64.tar.gz',
      url: server.url('/asset'),
      size: payload.length,
      sha256: sha256Hex(payload),
    );
  });

  tearDown(() async {
    await server.close();
    await tmp.delete(recursive: true);
  });

  test('downloads, reports progress, verifies and renames into place', () async {
    final events = <DownloadProgress>[];
    var verifying = 0;
    final file = await downloader().download(
      asset,
      dir: tmp,
      onProgress: events.add,
      onVerifying: () => verifying++,
    );

    expect(file.path, endsWith('Thelxis-0.2.0-linux-x64.tar.gz'));
    expect(await file.readAsBytes(), payload);
    expect(filesIn(tmp), ['Thelxis-0.2.0-linux-x64.tar.gz'], reason: 'no .part left behind');
    expect(verifying, 1);

    expect(events.length, greaterThan(2));
    for (var i = 1; i < events.length; i++) {
      expect(events[i].received, greaterThanOrEqualTo(events[i - 1].received));
    }
    expect(events.last.received, payload.length);
    expect(events.last.fraction, 1.0);
    expect(server.userAgents.single, 'Thelxis/9.9.9');
  });

  test('follows redirects, like GitHub releases/latest/download', () async {
    server.handler = (request) async {
      switch (request.uri.path) {
        case '/latest':
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(HttpHeaders.locationHeader, '/objects/abc');
          await request.response.close();
        case '/objects/abc':
          request.response.statusCode = HttpStatus.temporaryRedirect;
          request.response.headers.set(HttpHeaders.locationHeader, server.url('/final').toString());
          await request.response.close();
        default:
          await serveFull(request);
      }
    };
    final redirected = UpdateAsset(name: asset.name, url: server.url('/latest'), size: asset.size, sha256: asset.sha256);

    final file = await downloader().download(redirected, dir: tmp);
    expect(await file.readAsBytes(), payload);
    expect(server.requests, ['/latest', '/objects/abc', '/final']);
  });

  test('refuses redirects to other schemes and redirect loops', () async {
    server.handler = (request) async {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(HttpHeaders.locationHeader, 'ftp://example.com/file');
      await request.response.close();
    };
    expect((await failureOf(downloader(attempts: 1).download(asset, dir: tmp))).kind, UpdateErrorKind.network);

    server.handler = (request) async {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(HttpHeaders.locationHeader, '/again');
      await request.response.close();
    };
    expect((await failureOf(downloader().download(asset, dir: tmp))).kind, UpdateErrorKind.http);
  });

  group('integrity', () {
    test('size mismatch: the server announces a different length', () async {
      server.handler = (request) => serveFull(request, body: [...payload, 1, 2, 3]);
      final e = await failureOf(downloader().download(asset, dir: tmp));
      expect(e.kind, UpdateErrorKind.size);
      expect(filesIn(tmp), isEmpty);
    });

    test('size mismatch: a chunked body that is too long stops early', () async {
      server.handler = (request) async {
        request.response.headers.chunkedTransferEncoding = true;
        request.response.add([...payload, ...payload]);
        await request.response.close();
      };
      final e = await failureOf(downloader().download(asset, dir: tmp));
      expect(e.kind, UpdateErrorKind.size);
      expect(filesIn(tmp), isEmpty);
    });

    test('size mismatch: a chunked body that ends early is not resumable garbage', () async {
      server.handler = (request) async {
        request.response.headers.chunkedTransferEncoding = true;
        request.response.add(payload.sublist(0, 1000));
        await request.response.close();
      };
      final e = await failureOf(downloader().download(asset, dir: tmp));
      expect(e.kind, UpdateErrorKind.size);
      expect(filesIn(tmp), isEmpty);
    });

    test('SHA-256 mismatch discards the file', () async {
      final tampered = Uint8List.fromList(payload)..[1000] ^= 0xff;
      server.handler = (request) => serveFull(request, body: tampered);
      final e = await failureOf(downloader().download(asset, dir: tmp));
      expect(e.kind, UpdateErrorKind.hash);
      expect(filesIn(tmp), isEmpty, reason: 'neither final file nor .part may remain');
    });

    test('verifyFile checks size then hash and can delete the culprit', () async {
      final dl = downloader();
      final file = File('${tmp.path}/x.bin')..writeAsBytesSync(payload);
      await dl.verifyFile(file, asset);

      final wrongSize = UpdateAsset(name: 'x', url: asset.url, size: payload.length + 1, sha256: asset.sha256);
      expect((await failureOf(dl.verifyFile(file, wrongSize))).kind, UpdateErrorKind.size);
      expect(file.existsSync(), isTrue);

      final wrongHash = UpdateAsset(name: 'x', url: asset.url, size: payload.length, sha256: sha256Hex([9]));
      expect((await failureOf(dl.verifyFile(file, wrongHash, deleteOnFailure: true))).kind, UpdateErrorKind.hash);
      expect(file.existsSync(), isFalse);

      expect((await failureOf(dl.verifyFile(file, asset))).kind, UpdateErrorKind.storage);
    });
  });

  group('resume', () {
    test('continues a partial download with a Range request', () async {
      File('${tmp.path}/${asset.fileName}.part').writeAsBytesSync(payload.sublist(0, 100000));
      server.handler = (request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader)!;
        final start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${payload.length - 1}/${payload.length}',
        );
        await serveFull(request, body: payload.sublist(start));
      };

      final file = await downloader().download(asset, dir: tmp);
      expect(await file.readAsBytes(), payload);
      expect(server.rangeHeaders.single, 'bytes=100000-');
    });

    test('restarts when the server ignores Range', () async {
      File('${tmp.path}/${asset.fileName}.part').writeAsBytesSync(payload.sublist(0, 5000));
      final file = await downloader().download(asset, dir: tmp); // default handler: always 200 + full body
      expect(await file.readAsBytes(), payload);
      expect(server.rangeHeaders.single, 'bytes=5000-');
    });

    test('restarts when the partial file does not fit (416)', () async {
      File('${tmp.path}/${asset.fileName}.part').writeAsBytesSync(payload.sublist(0, 5000));
      var first = true;
      server.handler = (request) async {
        if (first) {
          first = false;
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          await request.response.close();
        } else {
          await serveFull(request);
        }
      };
      final file = await downloader().download(asset, dir: tmp);
      expect(await file.readAsBytes(), payload);
      expect(server.rangeHeaders, ['bytes=5000-', null]);
    });

    test('a dropped connection is resumed automatically', () async {
      var calls = 0;
      server.handler = (request) async {
        calls++;
        if (calls == 1) {
          await serveTruncated(request, 60000);
          return;
        }
        final range = request.headers.value(HttpHeaders.rangeHeader);
        expect(range, isNotNull, reason: 'second attempt must resume');
        final start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range!)![1]!);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${payload.length - 1}/${payload.length}',
        );
        await serveFull(request, body: payload.sublist(start));
      };

      final file = await downloader().download(asset, dir: tmp);
      expect(await file.readAsBytes(), payload);
      expect(calls, 2);
    });

    test('gives up after maxAttempts on persistent network failure', () async {
      server.handler = (request) => serveTruncated(request, 10);
      final e = await failureOf(downloader(attempts: 2).download(asset, dir: tmp));
      expect(e.kind, UpdateErrorKind.network);
      expect(server.requests.length, 2);
    });
  });

  test('HTTP errors are reported with the status and not retried for 4xx', () async {
    server.handler = (request) async {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    };
    final e = await failureOf(downloader().download(asset, dir: tmp));
    expect(e.kind, UpdateErrorKind.http);
    expect(e.status, 404);
    expect(server.requests.length, 1);
  });

  test('cancel aborts the transfer', () async {
    server.handler = (request) async {
      request.response.contentLength = payload.length;
      for (var i = 0; i < 100; i++) {
        request.response.add(payload.sublist(i * 1000, (i + 1) * 1000));
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await request.response.close();
    };
    final token = UpdateCancelToken();
    final started = Completer<void>();
    final future = downloader().download(
      asset,
      dir: tmp,
      cancel: token,
      onProgress: (p) {
        if (!started.isCompleted && p.received > 0) started.complete();
      },
    );
    await started.future;
    token.cancel();
    expect((await failureOf(future)).kind, UpdateErrorKind.cancelled);
  });

  test('an already downloaded valid file is reused without network access', () async {
    await downloader().download(asset, dir: tmp);
    server.requests.clear();
    final events = <DownloadProgress>[];
    final file = await downloader().download(asset, dir: tmp, onProgress: events.add);
    expect(await file.readAsBytes(), payload);
    expect(server.requests, isEmpty);
    expect(events.single.fraction, 1.0);
  });

  test('a corrupt leftover final file is replaced by a fresh download', () async {
    File('${tmp.path}/${asset.fileName}').writeAsBytesSync([1, 2, 3]);
    final file = await downloader().download(asset, dir: tmp);
    expect(await file.readAsBytes(), payload);
    expect(server.requests.length, 1);
  });

  test('cleanup removes stale files but keeps recent ones unless asked', () async {
    final old = File('${tmp.path}/old.bin')..writeAsBytesSync([1]);
    old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 30)));
    File('${tmp.path}/new.bin').writeAsBytesSync([1]);

    await downloader().cleanup(tmp);
    expect(filesIn(tmp), ['new.bin']);
    await downloader().cleanup(tmp, all: true);
    expect(filesIn(tmp), isEmpty);
  });
}
