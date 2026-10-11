import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:thelxis/files/file_channel.dart';
import 'package:thelxis/files/file_transfer_endpoint.dart';
import 'package:thelxis/files/protocol.dart';

/// A host endpoint talking to a hand-driven "viewer" that can send anything,
/// well-formed or not.
class RawPeer {
  RawPeer._(this.tmp, this.pair);

  final Directory tmp;
  final FileChannelPair pair;
  late final FileTransferEndpoint host;
  late final Directory incoming;
  late final Directory outside;
  bool allowed = true;
  final List<FileMsg> received = [];

  static Future<RawPeer> create({bool isHost = true}) async {
    final tmp = await Directory.systemTemp.createTemp('thelxis_raw_');
    final peer = RawPeer._(tmp, FileChannelPair());
    peer.incoming = await Directory('${tmp.path}/incoming').create();
    peer.outside = await Directory('${tmp.path}/outside').create();
    peer.host = FileTransferEndpoint(
      channel: peer.pair.b,
      isHost: isHost,
      filesAllowed: () => peer.allowed,
      incomingDir: () async => peer.incoming,
    );
    peer.pair.a.messages.listen((m) {
      if (m is FileTextMessage) {
        final d = FileMsg.decode(m.text);
        if (d != null) peer.received.add(d);
      }
    });
    return peer;
  }

  void send(FileMsg m) => pair.a.sendText(m.encode());
  void sendRawText(String s) => pair.a.sendText(s);
  void sendFrame(int xid, List<int> payload) => pair.a.sendBinary(FileFrame.encode(xid, payload));
  void sendRawBinary(Uint8List bytes) => pair.a.sendBinary(bytes);

  Future<T> next<T extends FileMsg>({bool Function(T)? where}) async {
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 10)) {
      for (final m in received) {
        if (m is T && (where == null || where(m))) {
          received.remove(m);
          return m;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    throw TimeoutException('no ${T.toString()} arrived; got ${received.map((m) => m.type).toList()}');
  }

  /// Lets everything in flight settle.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));

  /// Every path below the temp root, relative, sorted.
  Future<List<String>> snapshot() async {
    final out = <String>[];
    await for (final e in tmp.list(recursive: true, followLinks: false)) {
      out.add(e.path.substring(tmp.path.length));
    }
    out.sort();
    return out;
  }

  Future<void> dispose() async {
    await host.dispose();
    await tmp.delete(recursive: true);
  }
}
