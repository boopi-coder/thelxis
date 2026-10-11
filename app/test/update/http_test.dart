import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/update/manifest.dart';
import 'package:thelxis/update/manifest_loader.dart';
import 'package:thelxis/update/update_exception.dart';
import 'package:thelxis/update/update_http.dart';

import 'support/update_fakes.dart';

void main() {
  late HttpServer server;
  late Map<String, Future<void> Function(HttpRequest)> routes;
  final seenAgents = <String?>[];

  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  setUp(() async {
    routes = {};
    seenAgents.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      seenAgents.add(request.headers.value(HttpHeaders.userAgentHeader));
      final route = routes[request.uri.path];
      if (route == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      } else {
        await route(request);
      }
    });
  });
  tearDown(() => server.close(force: true));

  Future<void> body(HttpRequest r, List<int> bytes) async {
    r.response.add(bytes);
    await r.response.close();
  }

  Future<UpdateException> failureOf(Future<Object?> future) async {
    try {
      await future;
    } on UpdateException catch (e) {
      return e;
    }
    fail('expected an UpdateException');
  }

  group('UpdateHttp.getBytes', () {
    test('returns the body, follows redirects and sends the user agent', () async {
      routes['/a'] = (r) async {
        r.response.statusCode = HttpStatus.found;
        r.response.headers.set(HttpHeaders.locationHeader, '/b');
        await r.response.close();
      };
      routes['/b'] = (r) => body(r, [1, 2, 3]);

      final bytes = await UpdateHttp(userAgent: 'Thelxis/0.1.0').getBytes(url('/a'), maxBytes: 100);
      expect(bytes, [1, 2, 3]);
      expect(seenAgents, everyElement('Thelxis/0.1.0'));
    });

    test('a body above the limit is rejected, announced or not', () async {
      routes['/announced'] = (r) async {
        r.response.contentLength = 1000;
        await body(r, List.filled(1000, 7));
      };
      routes['/chunked'] = (r) async {
        r.response.headers.chunkedTransferEncoding = true;
        await body(r, List.filled(1000, 7));
      };
      for (final path in ['/announced', '/chunked']) {
        final e = await failureOf(UpdateHttp().getBytes(url(path), maxBytes: 999));
        expect(e.kind, UpdateErrorKind.manifest, reason: path);
      }
      expect(await UpdateHttp().getBytes(url('/announced'), maxBytes: 1000), hasLength(1000));
    });

    test('non-200 answers carry their status', () async {
      final e = await failureOf(UpdateHttp().getBytes(url('/missing'), maxBytes: 10));
      expect(e.kind, UpdateErrorKind.http);
      expect(e.status, 404);
    });

    test('an unreachable host is a network error', () async {
      final dead = url('/x');
      await server.close(force: true);
      final e = await failureOf(UpdateHttp(connectTimeout: const Duration(seconds: 2)).getBytes(dead, maxBytes: 10));
      expect(e.kind, UpdateErrorKind.network);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0); // for tearDown
    });
  });

  group('ManifestLoader over real HTTP', () {
    late TestSigner signer;
    setUpAll(() async => signer = await TestSigner.create());

    ManifestLoader loader() => ManifestLoader(
          http: UpdateHttp(),
          verifier: ed25519Verifier(publicKey: signer.publicKey),
          manifestUrl: url('/releases/latest/download/update.json'),
          signatureUrl: url('/releases/latest/download/update.json.sig'),
        );

    test('fetches both files, verifies and parses', () async {
      final manifest = manifestBytes();
      routes['/releases/latest/download/update.json'] = (r) => body(r, manifest);
      routes['/releases/latest/download/update.json.sig'] = (r) async => body(r, await signer.signatureFile(manifest));

      final parsed = await loader().load();
      expect(parsed.version, const SemVer(0, 2, 0));
    });

    test('a release without update.json.sig is rejected as unsigned', () async {
      routes['/releases/latest/download/update.json'] = (r) => body(r, manifestBytes());
      final e = await failureOf(loader().load());
      expect(e.kind, UpdateErrorKind.signatureMissing);
    });

    test('an oversized manifest is refused before it is verified', () async {
      routes['/releases/latest/download/update.json'] = (r) => body(r, Uint8List(kMaxManifestBytes + 1));
      routes['/releases/latest/download/update.json.sig'] = (r) => body(r, Uint8List(0));
      final e = await failureOf(loader().load());
      expect(e.kind, UpdateErrorKind.manifest);
    });
  });
}
