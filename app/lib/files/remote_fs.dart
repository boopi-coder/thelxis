import 'dart:async';

import 'protocol.dart';

enum RemoteFsErrorKind { notFound, denied, io, timeout, closed, unsupported }

class RemoteFsException implements Exception {
  const RemoteFsException(this.kind, [this.message = '']);
  final RemoteFsErrorKind kind;
  final String message;

  @override
  String toString() => 'RemoteFsException(${kind.name}${message.isEmpty ? '' : ': $message'})';
}

/// Viewer-side client for browsing the host's filesystem. Request/response
/// pairs are matched by `rid`; large folders arrive in pages that [list]
/// stitches together.
class RemoteFs {
  RemoteFs({
    required this.transmit,
    this.timeout = const Duration(seconds: 20),
  }) : supported = true;

  /// The host side has nothing to browse; every call throws `unsupported`.
  RemoteFs.unsupported()
      : transmit = _discard,
        timeout = Duration.zero,
        supported = false;

  static void _discard(FileMsg _) {}

  /// Hard stop for runaway or hostile listings.
  static const int maxEntries = 100000;

  /// Puts a request on the wire.
  final void Function(FileMsg message) transmit;
  final Duration timeout;
  final bool supported;

  int _nextRid = 1;
  final Map<int, Completer<FileMsg>> _pending = {};

  Future<List<FsRoot>> roots() async {
    final reply = await _request((rid) => FsRoots(rid));
    if (reply is FsRootsReply) return reply.items;
    throw _asException(reply);
  }

  Future<List<RemoteEntry>> list(String path) async {
    final out = <RemoteEntry>[];
    var offset = 0;
    while (true) {
      final reply = await _request((rid) => FsList(rid, path, offset: offset));
      if (reply is! FsListReply) throw _asException(reply);
      out.addAll(reply.items);
      offset += reply.items.length;
      final total = reply.total;
      // Peers that do not page send everything and omit `total`.
      if (total == null || reply.items.isEmpty || offset >= total || out.length >= maxEntries) {
        return out;
      }
    }
  }

  /// Feeds a reply from the channel.
  void handle(FileMsg message) {
    final int rid;
    switch (message) {
      case FsRootsReply():
        rid = message.rid;
      case FsListReply():
        rid = message.rid;
      case FsErr():
        rid = message.rid;
      default:
        return;
    }
    final waiter = _pending.remove(rid);
    if (waiter != null && !waiter.isCompleted) waiter.complete(message);
  }

  /// Fails every outstanding request (channel closed / endpoint disposed).
  void failAll([RemoteFsException? error]) {
    final e = error ?? const RemoteFsException(RemoteFsErrorKind.closed);
    final waiters = _pending.values.toList();
    _pending.clear();
    for (final w in waiters) {
      if (!w.isCompleted) w.completeError(e);
    }
  }

  Future<FileMsg> _request(FileMsg Function(int rid) build) async {
    if (!supported) throw const RemoteFsException(RemoteFsErrorKind.unsupported);
    final rid = _nextRid++;
    final waiter = Completer<FileMsg>();
    _pending[rid] = waiter;
    transmit(build(rid));
    try {
      return await waiter.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(rid);
      throw const RemoteFsException(RemoteFsErrorKind.timeout);
    }
  }

  RemoteFsException _asException(FileMsg reply) {
    if (reply is FsErr) {
      final kind = switch (reply.code) {
        FsErrCode.notFound => RemoteFsErrorKind.notFound,
        FsErrCode.denied => RemoteFsErrorKind.denied,
        FsErrCode.io => RemoteFsErrorKind.io,
      };
      return RemoteFsException(kind, reply.message);
    }
    return const RemoteFsException(RemoteFsErrorKind.io, 'unexpected_reply');
  }
}
