import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../core/log.dart';
import '../protocol/signaling_messages.dart';

const _log = Logger('ws');

/// PROTOCOL.md section 8: larger frames are a protocol violation.
const int kMaxFrameChars = 1 << 20;

class WsClosedException implements Exception {
  const WsClosedException([this.reason = 'closed']);
  final String reason;

  @override
  String toString() => 'WsClosedException($reason)';
}

/// A WebSocket speaking [SignalingMessage]s. Before [listen] is called,
/// inbound messages are buffered so the handshake can `await next()`; after
/// that they are pushed to the handler, preserving order.
class WsPeer {
  WsPeer(this._socket, {this.remoteIp = ''}) {
    _sub = _socket.listen(
      _onData,
      onDone: _onDone,
      onError: (Object e) {
        _fail('socket error');
        _finish();
      },
      cancelOnError: true,
    );
  }

  final WebSocket _socket;
  final String remoteIp;
  late final StreamSubscription<dynamic> _sub;

  final Queue<SignalingMessage> _queue = Queue();
  Completer<void>? _waiter;
  void Function(SignalingMessage message)? _handler;
  void Function()? _onClose;
  bool _closed = false;

  /// Completes when the stream is over: the peer's close frame arrived (or the
  /// socket failed).
  final Completer<void> _finished = Completer<void>();

  DateTime lastActivity = DateTime.now();

  bool get isClosed => _closed;

  /// Waits for the next known message. Throws [TimeoutException] or
  /// [WsClosedException].
  Future<SignalingMessage> next({required Duration timeout}) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (_queue.isNotEmpty) return _queue.removeFirst();
      if (_closed) throw const WsClosedException();
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) throw TimeoutException('no message', timeout);
      final waiter = _waiter = Completer<void>();
      await waiter.future.timeout(remaining, onTimeout: () {});
      if (identical(_waiter, waiter)) _waiter = null;
    }
  }

  /// Switches to push mode. Buffered messages are delivered first.
  void listen({
    required void Function(SignalingMessage message) onMessage,
    required void Function() onClose,
  }) {
    _handler = onMessage;
    _onClose = onClose;
    while (_queue.isNotEmpty && _handler != null) {
      onMessage(_queue.removeFirst());
    }
    if (_closed) {
      scheduleMicrotask(onClose);
    }
  }

  void send(SignalingMessage message) {
    if (_closed) return;
    try {
      _socket.add(jsonEncode(message.toJson()));
    } on Object catch (e) {
      _log.w('send failed', e);
      _fail('send failed');
    }
  }

  Future<void> close([int code = WebSocketStatus.normalClosure, String reason = '']) async {
    if (_closed) return;
    _closed = true;
    _wake();
    // `close()` only says our own close frame is out. The subscription must
    // stay until the peer's close frame has come in through it: cancelling
    // earlier hides that frame from dart:io, which then keeps the socket and a
    // five second timer alive.
    try {
      await _socket.close(code, reason).timeout(const Duration(seconds: 2));
      await _finished.future.timeout(const Duration(seconds: 2));
    } on Object {
      // The peer may already be gone; nothing to clean up.
    }
    unawaited(_sub.cancel());
    _notifyClosed();
  }

  void _onData(dynamic data) {
    if (_closed) return;
    lastActivity = DateTime.now();
    if (data is! String) {
      _fail('binary frame');
      return;
    }
    if (data.length > kMaxFrameChars) {
      _fail('frame too large');
      return;
    }
    Object? json;
    try {
      json = jsonDecode(data);
    } on FormatException {
      _fail('malformed json');
      return;
    }
    final message = SignalingMessage.parse(json);
    if (message == null) {
      _log.d('ignoring unknown message type');
      return;
    }
    final h = _handler;
    if (h != null) {
      h(message);
    } else {
      if (_queue.length >= 64) {
        _fail('too many pending messages');
        return;
      }
      _queue.add(message);
      _wake();
    }
  }

  void _onDone() {
    _closed = true;
    _finish();
    _wake();
    _notifyClosed();
  }

  void _finish() {
    if (!_finished.isCompleted) _finished.complete();
  }

  void _fail(String why) {
    if (_closed) return;
    _log.d('closing: $why');
    unawaited(close(WebSocketStatus.protocolError, why));
  }

  void _wake() {
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  void _notifyClosed() {
    final cb = _onClose;
    _onClose = null;
    cb?.call();
  }
}
