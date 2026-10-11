import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'update_exception.dart';

/// Thin `dart:io` HTTP helper for the updater.
///
/// Redirects are followed by hand so that an `https` request can never be
/// downgraded to `http` (GitHub's `releases/latest/download/...` redirects to
/// objects.githubusercontent.com), and so a `Range` header survives each hop.
class UpdateHttp {
  UpdateHttp({
    this.userAgent = 'Thelxis',
    this.connectTimeout = const Duration(seconds: 20),
    this.headersTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(seconds: 30),
    this.maxRedirects = 8,
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final String userAgent;
  final Duration connectTimeout;

  /// Max wait for the response headers after the request was sent.
  final Duration headersTimeout;

  /// Max silence between two body chunks.
  final Duration idleTimeout;
  final int maxRedirects;
  final HttpClient Function() _clientFactory;

  /// GETs [url] (following redirects) and hands the final response to [body].
  /// The client is closed when [body] completes, fails or [cancel] fires.
  Future<T> get<T>(
    Uri url,
    Future<T> Function(HttpClientResponse response) body, {
    Map<String, String> headers = const {},
    UpdateCancelToken? cancel,
  }) async {
    final client = _clientFactory()
      ..connectionTimeout = connectTimeout
      ..userAgent = userAgent
      // Raw bytes only: sizes and hashes are of the exact payload on the wire.
      ..autoUncompress = false;
    final unregister = cancel?.onCancel(() => client.close(force: true));
    try {
      var current = url;
      for (var hop = 0; hop <= maxRedirects; hop++) {
        cancel?.throwIfCancelled();
        final request = await client.getUrl(current);
        request.followRedirects = false;
        headers.forEach(request.headers.set);
        final response = await request.close().timeout(headersTimeout);
        if (_isRedirect(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.drain<void>().timeout(headersTimeout);
          if (location == null) {
            throw UpdateException(UpdateErrorKind.http, 'redirect without Location from ${current.host}');
          }
          final next = current.resolve(location);
          if (next.scheme != 'https' && !(next.scheme == 'http' && current.scheme == 'http')) {
            throw UpdateException(UpdateErrorKind.network, 'refusing redirect to ${next.scheme}');
          }
          current = next;
          continue;
        }
        return await body(response);
      }
      throw const UpdateException(UpdateErrorKind.http, 'too many redirects');
    } on UpdateException {
      rethrow;
    } on TimeoutException catch (e) {
      throw _mapped(cancel, 'timeout', e);
    } on SocketException catch (e) {
      throw _mapped(cancel, 'socket error: ${e.message}', e);
    } on HttpException catch (e) {
      throw _mapped(cancel, 'http error: ${e.message}', e);
    } on TlsException catch (e) {
      throw _mapped(cancel, 'tls error: ${e.message}', e);
    } finally {
      unregister?.call();
      client.close(force: true);
    }
  }

  /// GETs [url] into memory, at most [maxBytes]. Non-200 → [UpdateErrorKind.http].
  Future<Uint8List> getBytes(
    Uri url, {
    required int maxBytes,
    UpdateCancelToken? cancel,
  }) {
    return get<Uint8List>(url, (response) async {
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>().timeout(headersTimeout);
        throw UpdateException(
          UpdateErrorKind.http,
          'HTTP ${response.statusCode} for ${url.host}${url.path}',
          status: response.statusCode,
        );
      }
      if (response.contentLength > maxBytes) {
        throw UpdateException(UpdateErrorKind.manifest, 'response larger than $maxBytes bytes');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(idleTimeout)) {
        builder.add(chunk);
        if (builder.length > maxBytes) {
          throw UpdateException(UpdateErrorKind.manifest, 'response larger than $maxBytes bytes');
        }
      }
      return builder.takeBytes();
    }, cancel: cancel);
  }

  static bool _isRedirect(int status) =>
      status == HttpStatus.movedPermanently ||
      status == HttpStatus.found ||
      status == HttpStatus.seeOther ||
      status == HttpStatus.temporaryRedirect ||
      status == 308;

  static UpdateException _mapped(UpdateCancelToken? cancel, String detail, Object cause) {
    if (cancel?.isCancelled ?? false) {
      return UpdateException(UpdateErrorKind.cancelled, 'cancelled', cause: cause);
    }
    return UpdateException(UpdateErrorKind.network, detail, cause: cause);
  }
}
