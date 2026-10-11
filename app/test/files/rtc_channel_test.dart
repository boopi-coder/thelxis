import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:thelxis/files/file_channel.dart';

/// Stand-in for the flutter_webrtc data channel. Like the real one it caches
/// the buffered amount and only refreshes it from drain events.
class FakeDataChannel extends RTCDataChannel {
  FakeDataChannel({RTCDataChannelState initial = RTCDataChannelState.RTCDataChannelOpen}) : _state = initial {
    stateChangeStream = _states.stream;
    messageStream = _messages.stream;
  }

  final StreamController<RTCDataChannelState> _states = StreamController.broadcast(sync: true);
  final StreamController<RTCDataChannelMessage> _messages = StreamController.broadcast(sync: true);
  RTCDataChannelState _state;
  final List<RTCDataChannelMessage> sent = [];
  int nativeBuffered = 0;
  int cached = 0;
  int getBufferedCalls = 0;
  bool closed = false;

  @override
  RTCDataChannelState? get state => _state;
  @override
  int? get id => 1;
  @override
  String? get label => 'files';
  @override
  int? get bufferedAmount => cached;

  @override
  Future<int> getBufferedAmount() async {
    getBufferedCalls++;
    cached = nativeBuffered;
    return nativeBuffered;
  }

  @override
  Future<void> send(RTCDataChannelMessage message) async {
    sent.add(message);
    if (message.isBinary) nativeBuffered += message.binary.length;
  }

  /// Engine drained [bytes]; [report] false simulates a lost event.
  void drain(int bytes, {bool report = true}) {
    nativeBuffered -= bytes;
    if (report) {
      cached = nativeBuffered;
      onBufferedAmountChange?.call(nativeBuffered, -bytes);
    }
  }

  void setState(RTCDataChannelState s) {
    _state = s;
    _states.add(s);
  }

  void receive(RTCDataChannelMessage m) => _messages.add(m);

  @override
  Future<void> close() async {
    closed = true;
    _state = RTCDataChannelState.RTCDataChannelClosed;
  }
}

Uint8List bytes(int n) => Uint8List(n);

void main() {
  test('messages that arrive before anyone listens are not lost', () async {
    final dc = FakeDataChannel();
    final ch = RtcFileChannel(dc);
    dc.receive(RTCDataChannelMessage('{"t":"ok","xid":1}'));
    dc.receive(RTCDataChannelMessage.fromBinary(Uint8List.fromList([0, 0, 0, 1, 9])));
    final got = await ch.messages.take(2).toList();
    expect(got[0], isA<FileTextMessage>().having((m) => m.text, 'text', '{"t":"ok","xid":1}'));
    expect(got[1], isA<FileBinaryMessage>().having((m) => m.bytes.last, 'last', 9));
  });

  test('sends keep their order', () async {
    final dc = FakeDataChannel();
    final ch = RtcFileChannel(dc);
    ch.sendText('a');
    ch.sendBinary(bytes(3));
    ch.sendText('b');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(dc.sent.map((m) => m.isBinary ? 'bin' : m.text), ['a', 'bin', 'b']);
  });

  test('sends issued while the channel is still connecting go out after it opens', () async {
    final dc = FakeDataChannel(initial: RTCDataChannelState.RTCDataChannelConnecting);
    final ch = RtcFileChannel(dc);
    ch.sendText('early');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(dc.sent, isEmpty);
    dc.setState(RTCDataChannelState.RTCDataChannelOpen);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(dc.sent.single.text, 'early');
  });

  test('bufferedAmount counts what we sent even though the plugin only reports drains', () async {
    final dc = FakeDataChannel();
    final ch = RtcFileChannel(dc);
    ch.sendBinary(bytes(1000));
    ch.sendBinary(bytes(500));
    expect(ch.bufferedAmount, 1500, reason: 'queued bytes count immediately');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(dc.cached, 0, reason: 'the plugin has not reported anything yet');
    expect(ch.bufferedAmount, 1500);
    dc.drain(1000);
    expect(ch.bufferedAmount, 500);
    dc.drain(500);
    expect(ch.bufferedAmount, 0);
  });

  test('waitBufferedBelow wakes on a drain event', () async {
    final dc = FakeDataChannel();
    final ch = RtcFileChannel(dc);
    ch.sendBinary(bytes(5000));
    var done = false;
    final wait = ch.waitBufferedBelow(1000).then((_) => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(done, isFalse);
    dc.drain(5000);
    await wait.timeout(const Duration(seconds: 1));
    expect(done, isTrue);
  });

  test('waitBufferedBelow does not hang when the drain event is lost', () async {
    final dc = FakeDataChannel();
    final ch = RtcFileChannel(dc);
    ch.sendBinary(bytes(5000));
    final wait = ch.waitBufferedBelow(1000);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    dc.drain(5000, report: false);
    await wait.timeout(const Duration(seconds: 2));
    expect(dc.getBufferedCalls, greaterThan(0));
  });

  test('waitBufferedBelow returns immediately when under the mark', () async {
    final ch = RtcFileChannel(FakeDataChannel());
    await ch.waitBufferedBelow(1000).timeout(const Duration(milliseconds: 200));
  });

  test('a close by the peer completes the stream and releases waiters', () async {
    final dc = FakeDataChannel();
    final ch = RtcFileChannel(dc);
    ch.sendBinary(bytes(5000));
    final done = Completer<void>();
    ch.messages.listen((_) {}, onDone: done.complete);
    final wait = ch.waitBufferedBelow(0);
    dc.setState(RTCDataChannelState.RTCDataChannelClosed);
    await done.future.timeout(const Duration(seconds: 1));
    await wait.timeout(const Duration(seconds: 1));
    expect(ch.isOpen, isFalse);
    ch.sendText('dropped'); // must not throw
  });

  test('close() closes the underlying channel and is idempotent', () async {
    final dc = FakeDataChannel();
    final ch = RtcFileChannel(dc);
    await ch.close();
    await ch.close();
    expect(dc.closed, isTrue);
    expect(ch.isOpen, isFalse);
  });

  test('a channel that is already closed when wrapped reports closed', () async {
    final ch = RtcFileChannel(FakeDataChannel(initial: RTCDataChannelState.RTCDataChannelClosed));
    expect(ch.isOpen, isFalse);
    await ch.messages.toList().timeout(const Duration(seconds: 1));
  });

  group('FileChannelPair', () {
    test('delivers in order, later than the call, and buffers before listen', () async {
      final pair = FileChannelPair();
      final seen = <String>[];
      pair.a.sendText('1');
      pair.a.sendText('2');
      expect(seen, isEmpty);
      pair.b.messages.listen((m) => seen.add((m as FileTextMessage).text));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(seen, ['1', '2']);
    });

    test('close propagates to the peer', () async {
      final pair = FileChannelPair();
      final done = Completer<void>();
      pair.b.messages.listen((_) {}, onDone: done.complete);
      await pair.a.close();
      await done.future.timeout(const Duration(seconds: 1));
      expect(pair.b.isOpen, isFalse);
    });

    test('held channels accumulate bufferedAmount and release drains it', () async {
      final pair = FileChannelPair();
      pair.b.messages.listen((_) {});
      pair.a.held = true;
      pair.a.sendBinary(bytes(1000));
      pair.a.sendBinary(bytes(1000));
      expect(pair.a.bufferedAmount, 2000);
      final wait = pair.a.waitBufferedBelow(0);
      pair.a.release();
      await wait.timeout(const Duration(seconds: 1));
      expect(pair.a.bufferedAmount, 0);
    });
  });
}
