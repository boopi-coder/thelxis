import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/log.dart';

const Logger _log = Logger('files.channel');

/// The sender pauses while more than this many bytes sit in the channel's
/// send buffer (PROTOCOL §6.4). libwebrtc kills a channel at 16 MiB, so 1 MiB
/// leaves a wide safety margin and still keeps the link saturated.
const int kHighWaterBytes = 1 << 20;

/// What the transfer code needs from the `files` data channel, and nothing
/// more. Keeping it this small lets the whole module be tested in memory.
abstract class FileChannel {
  /// Queues a text (JSON) frame. Never throws; frames sent on a closed
  /// channel are dropped (the closed [messages] stream reports the loss).
  void sendText(String text);

  /// Queues a binary frame. Same contract as [sendText].
  void sendBinary(Uint8List bytes);

  /// Incoming frames in arrival order. Single-subscription and buffering, so
  /// frames that arrive before the first listener are not lost. Completes
  /// when the channel is closed (locally or by the peer).
  Stream<FileChannelMessage> get messages;

  /// Bytes accepted by [sendText]/[sendBinary] that have not left yet.
  int get bufferedAmount;

  /// Completes once [bufferedAmount] is at or below [bytes], or the channel
  /// closed. Must never hang on a missed event.
  Future<void> waitBufferedBelow(int bytes);

  bool get isOpen;

  Future<void> close();
}

sealed class FileChannelMessage {
  const FileChannelMessage();
}

final class FileTextMessage extends FileChannelMessage {
  const FileTextMessage(this.text);
  final String text;
}

final class FileBinaryMessage extends FileChannelMessage {
  const FileBinaryMessage(this.bytes);
  final Uint8List bytes;
}

/// [FileChannel] over a flutter_webrtc [RTCDataChannel].
///
/// Construct it synchronously when the channel is created / handed over by
/// `onDataChannel`: flutter_webrtc's own message stream does not replay, this
/// adapter buffers from the moment it exists. Do not also assign
/// `onMessage` / `onBufferedAmountChange` on the wrapped channel.
class RtcFileChannel implements FileChannel {
  RtcFileChannel(this._dc) {
    _dc.onBufferedAmountChange = _onBufferedChange;
    _messageSub = _dc.messageStream.listen(
      _onMessage,
      onDone: _markClosed,
      onError: (Object e) => _log.w('data channel error', e),
    );
    _stateSub = _dc.stateChangeStream.listen(_onState, onDone: _markClosed);
    final state = _dc.state;
    if (state == RTCDataChannelState.RTCDataChannelOpen) {
      _isOpen = true;
    } else if (state == RTCDataChannelState.RTCDataChannelClosing ||
        state == RTCDataChannelState.RTCDataChannelClosed) {
      _markClosed();
    }
  }

  final RTCDataChannel _dc;
  final StreamController<FileChannelMessage> _incoming = StreamController<FileChannelMessage>();
  StreamSubscription<RTCDataChannelMessage>? _messageSub;
  StreamSubscription<RTCDataChannelState>? _stateSub;

  // Frames issued while the channel is still connecting wait here, in order.
  final List<(RTCDataChannelMessage, int)> _beforeOpen = [];
  bool _isOpen = false;
  bool _closed = false;

  // libwebrtc only reports the buffer when it *drains*, so the number the
  // plugin caches goes stale as soon as we send. Estimate it ourselves:
  //   last value reported by the engine + bytes handed over since + bytes
  //   still queued in Dart.
  int _native = 0;
  int _handedSinceReport = 0;
  int _queued = 0;
  Completer<void>? _drainWake;

  @override
  Stream<FileChannelMessage> get messages => _incoming.stream;

  @override
  bool get isOpen => !_closed;

  @override
  int get bufferedAmount => _native + _handedSinceReport + _queued;

  @override
  void sendText(String text) => _send(RTCDataChannelMessage(text), 0);

  @override
  void sendBinary(Uint8List bytes) {
    _send(RTCDataChannelMessage.fromBinary(bytes), bytes.length);
  }

  void _send(RTCDataChannelMessage message, int accounted) {
    if (_closed) return;
    _queued += accounted;
    if (_isOpen) {
      _dispatch(message, accounted);
    } else {
      _beforeOpen.add((message, accounted));
    }
  }

  /// Platform-channel calls reach the engine in call order, so frames can be
  /// issued back to back without waiting for each reply; waiting per frame
  /// would cap throughput at one platform round trip per 64 KiB.
  void _dispatch(RTCDataChannelMessage message, int accounted) {
    _dc.send(message).then((_) {
      _queued -= accounted;
      _handedSinceReport += accounted;
    }, onError: (Object e) {
      _queued -= accounted;
      _log.w('send failed, closing', e);
      _markClosed();
    });
  }

  void _opened() {
    if (_isOpen || _closed) return;
    _isOpen = true;
    final waiting = List.of(_beforeOpen);
    _beforeOpen.clear();
    for (final (message, accounted) in waiting) {
      _dispatch(message, accounted);
    }
  }

  void _onMessage(RTCDataChannelMessage m) {
    if (_incoming.isClosed) return;
    _incoming.add(m.isBinary ? FileBinaryMessage(m.binary) : FileTextMessage(m.text));
  }

  void _onState(RTCDataChannelState state) {
    switch (state) {
      case RTCDataChannelState.RTCDataChannelOpen:
        _opened();
      case RTCDataChannelState.RTCDataChannelClosing:
      case RTCDataChannelState.RTCDataChannelClosed:
        _markClosed();
      case RTCDataChannelState.RTCDataChannelConnecting:
        break;
    }
  }

  void _onBufferedChange(int current, int changed) {
    _native = current;
    _handedSinceReport = 0;
    _wake();
  }

  void _wake() {
    final w = _drainWake;
    _drainWake = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  void _markClosed() {
    if (_closed) return;
    _closed = true;
    _beforeOpen.clear();
    _wake();
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }

  @override
  Future<void> waitBufferedBelow(int bytes) async {
    while (!_closed && bufferedAmount > bytes) {
      final wake = _drainWake ??= Completer<void>();
      var timedOut = false;
      // The engine's drain events are the fast path; the poll is the safety
      // net so a dropped event can never stall a transfer for good.
      await wake.future.timeout(const Duration(milliseconds: 100), onTimeout: () => timedOut = true);
      if (timedOut && !_closed) {
        try {
          _native = await _dc.getBufferedAmount();
          _handedSinceReport = 0;
        } catch (_) {
          _markClosed();
        }
      }
    }
  }

  @override
  Future<void> close() async {
    if (_closed && _incoming.isClosed) return;
    _markClosed();
    await _messageSub?.cancel();
    await _stateSub?.cancel();
    try {
      await _dc.close();
    } catch (e) {
      _log.d('close: $e');
    }
  }
}

/// In-memory [FileChannel] pair for tests (and anything else that wants to run
/// the transfer stack without WebRTC). Delivery happens on a later event-loop
/// turn like a real channel, never re-entrantly.
class FileChannelPair {
  FileChannelPair({int maxMessageBytes = 256 * 1024}) {
    a = MemoryFileChannel._(maxMessageBytes);
    b = MemoryFileChannel._(maxMessageBytes);
    a._peer = b;
    b._peer = a;
  }

  late final MemoryFileChannel a;
  late final MemoryFileChannel b;

  Future<void> close() async {
    await a.close();
    await b.close();
  }
}

class MemoryFileChannel implements FileChannel {
  MemoryFileChannel._(this.maxMessageBytes);

  /// SCTP in libwebrtc rejects bigger messages; enforcing it here catches
  /// protocol bugs (unpaged listings, oversized frames) in unit tests.
  final int maxMessageBytes;

  late final MemoryFileChannel _peer;
  final StreamController<FileChannelMessage> _incoming = StreamController<FileChannelMessage>();
  final Queue<(FileChannelMessage, int)> _outbox = Queue();
  Completer<void>? _drainWake;
  bool _scheduled = false;
  bool _closed = false;
  int _buffered = 0;

  /// While true nothing is delivered, so [bufferedAmount] keeps growing —
  /// the back-pressure tests' stand-in for a congested link.
  bool held = false;

  /// Observes every frame at send time (tests).
  void Function(FileChannelMessage message)? onSend;

  /// Total bytes ever queued, for assertions.
  int totalBytesSent = 0;
  int maxBufferedSeen = 0;

  @override
  Stream<FileChannelMessage> get messages => _incoming.stream;

  @override
  bool get isOpen => !_closed;

  @override
  int get bufferedAmount => _buffered;

  @override
  void sendText(String text) {
    _enqueue(FileTextMessage(text), utf8.encode(text).length);
  }

  @override
  void sendBinary(Uint8List bytes) => _enqueue(FileBinaryMessage(bytes), bytes.length);

  void _enqueue(FileChannelMessage message, int size) {
    if (_closed) return;
    if (size > maxMessageBytes) {
      throw StateError('message of $size bytes exceeds the channel limit of $maxMessageBytes');
    }
    onSend?.call(message);
    totalBytesSent += size;
    _buffered += size;
    if (_buffered > maxBufferedSeen) maxBufferedSeen = _buffered;
    _outbox.add((message, size));
    _schedule();
  }

  void _schedule() {
    if (held || _scheduled || _outbox.isEmpty) return;
    _scheduled = true;
    Timer.run(_deliver);
  }

  void _deliver() {
    _scheduled = false;
    while (!held && _outbox.isNotEmpty) {
      final (message, size) = _outbox.removeFirst();
      _buffered -= size;
      _peer._receive(message);
    }
    _wake();
  }

  void _receive(FileChannelMessage message) {
    if (!_incoming.isClosed) _incoming.add(message);
  }

  /// Lets queued frames flow again after [held] was set.
  void release() {
    held = false;
    _schedule();
  }

  void _wake() {
    final w = _drainWake;
    _drainWake = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  @override
  Future<void> waitBufferedBelow(int bytes) async {
    while (!_closed && _buffered > bytes) {
      final wake = _drainWake ??= Completer<void>();
      await wake.future;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _outbox.clear();
    _buffered = 0;
    _wake();
    unawaited(_incoming.close());
    // The peer learns about the close one turn later, like a real channel.
    Timer.run(() {
      if (!_peer._closed) unawaited(_peer.close());
    });
  }
}
