// Minimal TURN client (UDP or TCP) used by the server and service tests.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/net/connectivity/stun_crypto.dart';
import 'package:thelxis/net/connectivity/stun_message.dart';

/// Minimal TURN client over UDP or TCP, just enough to drive the server.
class TurnTestClient {
  TurnTestClient._(this._send, this.packets, this._close, this.localPort);

  final void Function(Uint8List) _send;
  final StreamController<Uint8List> packets;
  final void Function() _close;
  final int localPort;
  final List<Uint8List> _queue = [];
  Completer<void>? _waiter;
  String? realm;
  String? nonce;
  Uint8List? key;

  static Future<TurnTestClient> udp(int serverPort) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    late TurnTestClient client;
    final controller = StreamController<Uint8List>.broadcast();
    socket.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d != null) client._enqueue(d.data);
    });
    client = TurnTestClient._(
      (bytes) => socket.send(bytes, InternetAddress.loopbackIPv4, serverPort),
      controller,
      socket.close,
      socket.port,
    );
    return client;
  }

  static Future<TurnTestClient> tcp(int serverPort) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      serverPort,
    );
    late TurnTestClient client;
    final controller = StreamController<Uint8List>.broadcast();
    final buffer = BytesBuilder();
    socket.listen((chunk) {
      buffer.add(chunk);
      var data = buffer.takeBytes();
      var offset = 0;
      while (data.length - offset >= 4) {
        final view = ByteData.sublistView(data, offset);
        final isStun = (data[offset] & 0xC0) == 0;
        final len = isStun ? 20 + view.getUint16(2) : 4 + view.getUint16(2);
        final consumed = isStun ? len : (len + 3) & ~3;
        if (data.length - offset < consumed) break;
        client._enqueue(Uint8List.fromList(data.sublist(offset, offset + len)));
        offset += consumed;
      }
      if (offset < data.length) buffer.add(data.sublist(offset));
    });
    client = TurnTestClient._(
      socket.add,
      controller,
      socket.destroy,
      socket.port,
    );
    return client;
  }

  void _enqueue(Uint8List data) {
    _queue.add(data);
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  Future<Uint8List?> nextPacket({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (_queue.isEmpty) {
      final left = deadline.difference(DateTime.now());
      if (left.isNegative) return null;
      _waiter = Completer<void>();
      await Future.any([_waiter!.future, Future<void>.delayed(left)]);
    }
    return _queue.removeAt(0);
  }

  void sendRaw(Uint8List bytes) => _send(bytes);

  /// Sends [request] and returns the response with the same transaction id.
  Future<StunMessage> call(
    StunMessage request, {
    List<int>? integrityKey,
  }) async {
    _send(request.encode(integrityKey: integrityKey, fingerprint: true));
    for (;;) {
      final packet = await nextPacket();
      if (packet == null) fail('no response to method ${request.method}');
      final m = StunMessage.parse(packet);
      if (m == null) continue;
      if (_eq(m.transactionId, request.transactionId)) return m;
    }
  }

  /// Authenticated request with the 401 dance; returns the final response.
  Future<StunMessage> authed(
    int method,
    List<StunAttribute> attributes,
    String username,
    String password, {
    List<StunAttribute> Function(Uint8List tid)? attributesFor,
  }) async {
    final probeTid = randomTransactionId();
    if (key == null) {
      final probe = await call(
        StunMessage(
          method: method,
          messageClass: StunClass.request,
          transactionId: probeTid,
          attributes: attributesFor?.call(probeTid) ?? attributes,
        ),
      );
      if (probe.errorCode?.code != 401) return probe;
      realm = probe.stringAttribute(StunAttr.realm);
      nonce = probe.stringAttribute(StunAttr.nonce);
      key = longTermKey(
        utf8.encode(username),
        utf8.encode(realm!),
        utf8.encode(password),
      );
    }
    final tid = randomTransactionId();
    final response = await call(
      StunMessage(
        method: method,
        messageClass: StunClass.request,
        transactionId: tid,
        attributes: [
          ...(attributesFor?.call(tid) ?? attributes),
          StunAttribute.string(StunAttr.username, username),
          StunAttribute.string(StunAttr.realm, realm!),
          StunAttribute.string(StunAttr.nonce, nonce!),
        ],
      ),
      integrityKey: key,
    );
    if (response.errorCode?.code == 438) {
      nonce = response.stringAttribute(StunAttr.nonce);
    }
    return response;
  }

  void close() => _close();

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

StunAttribute transportUdp() => StunAttribute(
  StunAttr.requestedTransport,
  Uint8List.fromList([17, 0, 0, 0]),
);

/// XOR-PEER-ADDRESS for an IPv4 peer. IPv4 is XORed with the magic cookie
/// only, so the transaction id does not matter.
StunAttribute peerAttr(String ip, int port) => StunAttribute.xorAddress(
  StunAttr.xorPeerAddress,
  InternetAddress(ip),
  port,
  Uint8List(12),
);

StunAttribute channelNumberAttr(int n) {
  final v = Uint8List(4);
  ByteData.sublistView(v).setUint16(0, n);
  return StunAttribute(StunAttr.channelNumber, v);
}
