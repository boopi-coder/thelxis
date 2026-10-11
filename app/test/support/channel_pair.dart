import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:thelxis/core/identity.dart';
import 'package:thelxis/net/signaling_channel.dart';
import 'package:thelxis/net/ws_peer.dart';

/// A [SignalingChannel] over a real loopback WebSocket, plus the raw other
/// end so tests can see what the session sent to its peer.
class ChannelPair {
  ChannelPair._(this.channel, this.raw, this._server);

  final SignalingChannel channel;
  final WebSocket raw;
  final HttpServer _server;
  final List<Map<String, dynamic>> received = [];

  static Future<ChannelPair> create({
    required Identity self,
    required String peerKey,
    SignalingRole role = SignalingRole.listener,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<WsPeer>();
    server.listen((req) async {
      accepted.complete(WsPeer(await WebSocketTransformer.upgrade(req)));
    });
    final raw = await WebSocket.connect('ws://127.0.0.1:${server.port}/');
    final channel = SignalingChannel(
      sid: 'test-sid',
      identity: self,
      role: role,
      peerKey: peerKey,
      peer: await accepted.future,
      initialDialerNonce: 'nD',
      initialListenerNonce: 'nL',
    );
    final pair = ChannelPair._(channel, raw, server);
    raw.listen((d) => pair.received.add(jsonDecode(d as String) as Map<String, dynamic>));
    return pair;
  }

  bool get gotBye => received.any((m) => m['t'] == 'bye');

  String? get byeReason {
    for (final m in received) {
      if (m['t'] == 'bye') return m['reason'] as String?;
    }
    return null;
  }

  Future<void> close() async {
    channel.dispose();
    await raw.close();
    await _server.close(force: true);
  }
}
